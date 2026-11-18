import importlib.util
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]


def load_script(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


probe = load_script("connectivity_probe")
compare_routes = load_script("compare_routes")


class ProbeTests(unittest.TestCase):
    def test_connection_success_and_timeout_are_distinct(self):
        with mock.patch.object(probe.socket, "create_connection") as connect:
            self.assertTrue(probe.probe("oci", "10.29.0.4", 22)["connected"])
            connect.assert_called_once_with(("10.29.0.4", 22), timeout=8)
        with mock.patch.object(probe.socket, "create_connection", side_effect=TimeoutError("timed out")):
            result = probe.probe("oci", "10.29.0.4", 22)
            self.assertFalse(result["connected"])
            self.assertIn("timed out", result["error"])

    def test_target_arguments_must_be_pairs(self):
        with self.assertRaises(ValueError):
            probe.main(["oci"])


@unittest.skipUnless(shutil.which("pwsh"), "PowerShell 7 is required to exercise the collector")
class EvidenceCollectorTests(unittest.TestCase):
    def collect(self, allow_restricted=False):
        mock_az = r"""
$ErrorActionPreference = 'Stop'
function global:az {
    $global:LASTEXITCODE = 0
    $arguments = @($args)
    if ($arguments[0] -eq 'vm') {
        $nameIndex = [array]::IndexOf($arguments, '-n')
        $parameterIndex = [array]::IndexOf($arguments, '--parameters')
        $source = $arguments[$nameIndex + 1].Substring(3)
        $lines = @()
        for ($i = $parameterIndex + 1; $i -lt $arguments.Count - 5; $i += 2) {
            $target = $arguments[$i]
            $connected = $target -eq 'local' -or
                ($source -eq 'a' -and $target -eq 'oci') -or
                ($source -eq 'oci' -and $target -eq 'a') -or
                ($env:POC_TEST_ALLOW_RESTRICTED -eq '1' -and $source -eq 'a-no-oci' -and $target -eq 'oci')
            foreach ($port in @(22, 30289)) {
                $result = @{ target = $target; host = $arguments[$i + 1]; port = $port; connected = $connected }
                $lines += 'POC_RESULT=' + ($result | ConvertTo-Json -Compress)
            }
        }
        return (@{ value = @(@{ message = ($lines -join "`n") }) } | ConvertTo-Json -Compress -Depth 10)
    }
    if ($arguments[0] -eq 'network' -and $arguments[1] -eq 'nic' -and $arguments[2] -eq 'show') {
        return '{"privateIp":"10.0.0.4"}'
    }
    return '{"id":"/test/id","value":[]}'
}
try {
    & (Join-Path $env:POC_TEST_ROOT 'scripts\Collect-Evidence.ps1') `
        -ResourceGroup 'test-rg' -SubscriptionId 'test-sub' -EvidenceFile $env:POC_TEST_EVIDENCE
} catch {
    Write-Error $_
    exit 1
}
"""
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "evidence.json"
            environment = {
                **os.environ,
                "POC_TEST_ROOT": str(ROOT),
                "POC_TEST_EVIDENCE": str(path),
                "POC_TEST_ALLOW_RESTRICTED": "1" if allow_restricted else "0",
            }
            result = subprocess.run(
                ["pwsh", "-NoProfile", "-NonInteractive", "-Command", mock_az],
                text=True,
                capture_output=True,
                env=environment,
                check=False,
            )
            self.assertTrue(path.exists(), result.stdout + result.stderr)
            return result, json.loads(path.read_text(encoding="utf-8-sig"))

    def test_all_twelve_probes_include_both_restricted_directions(self):
        result, evidence = self.collect()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertTrue(evidence["complete"])
        self.assertEqual(12, len(evidence["acceptance"]))
        for source, target in (("a-no-oci", "oci"), ("oci", "a-no-oci")):
            rows = [r for r in evidence["acceptance"] if r["source"] == source and r["target"] == target]
            self.assertEqual({22, 30289}, {r["port"] for r in rows})
            self.assertTrue(all(r["passed"] and r["actual"] == "not connected" for r in rows))

    def test_unexpected_restricted_connection_is_a_failure(self):
        result, evidence = self.collect(allow_restricted=True)
        self.assertNotEqual(0, result.returncode)
        self.assertFalse(evidence["complete"])
        self.assertTrue(any(not row["passed"] and row["source"] == "a-no-oci" for row in evidence["acceptance"]))


class RouteComparisonTests(unittest.TestCase):
    @staticmethod
    def evidence(*routes):
        return {"nicRoutes": {"b": [{"value": list(routes)}]}}

    def test_removed_matching_route_does_not_hide_broader_routes(self):
        before = self.evidence(
            {"addressPrefix": ["10.29.0.0/22"], "state": "Active", "nextHopType": "VirtualNetworkGateway"},
            {"addressPrefix": ["10.0.0.0/8"], "state": "Active", "nextHopType": "VirtualNetworkGateway"},
        )
        after = self.evidence({"addressPrefix": ["10.0.0.0/8"], "state": "Active", "nextHopType": "VirtualNetworkGateway"})
        result = compare_routes.compare(before, after, "10.29.0.0/22")
        self.assertIn("disappeared", result["outcome"])
        self.assertEqual(["10.0.0.0/8 (VirtualNetworkGateway)"], result["after"]["broaderRoutes"])

    def test_missing_baseline_is_inconclusive_and_invalid_routes_are_ignored(self):
        before = self.evidence({"addressPrefix": ["not-a-prefix"]})
        after = self.evidence({"addressPrefix": ["10.29.0.0/22"], "state": "Invalid"})
        result = compare_routes.compare(before, after, "10.29.0.0/22")
        self.assertTrue(result["outcome"].startswith("inconclusive"))
        self.assertEqual([], result["after"]["matching"])

    def test_more_specific_route_still_present_is_not_full_filtering(self):
        before = self.evidence({"addressPrefixes": ["10.29.0.0/22", "10.29.0.0/24"]})
        after = self.evidence({"addressPrefixes": ["10.29.0.0/24"]})
        result = compare_routes.compare(before, after, "10.29.0.0/22")
        self.assertIn("remain", result["outcome"])
        self.assertEqual(["10.29.0.0/24"], result["after"]["matching"])

    def test_comparison_requires_matching_lab_and_map_association(self):
        before = {
            "complete": True,
            "subscriptionId": "sub",
            "resourceGroup": "rg",
            "hubConnections": {"b": {"routingConfiguration": {}}},
        }
        after = {
            **before,
            "routeMap": {"id": "/routeMaps/drop"},
            "hubConnections": {"b": {"routingConfiguration": {"outboundRouteMap": {"id": "/routeMaps/drop"}}}},
        }
        compare_routes.validate_snapshots(before, after)
        with self.assertRaisesRegex(ValueError, "resourceGroup"):
            compare_routes.validate_snapshots(before, {**after, "resourceGroup": "other"})
        with self.assertRaisesRegex(ValueError, "subscriptionId"):
            compare_routes.validate_snapshots(before, {**after, "subscriptionId": "other"})
        with self.assertRaisesRegex(ValueError, "Baseline already"):
            compare_routes.validate_snapshots(
                {**before, "hubConnections": after["hubConnections"]}, after
            )
        with self.assertRaisesRegex(ValueError, "not confirmed"):
            compare_routes.validate_snapshots(before, {**after, "routeMap": {"id": "/routeMaps/other"}})
        with self.assertRaisesRegex(ValueError, "completed"):
            compare_routes.validate_snapshots(before, {**after, "complete": False})


if __name__ == "__main__":
    unittest.main()
