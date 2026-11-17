import importlib.util
import pathlib
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
