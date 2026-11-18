# Run the vWAN-to-OCI connectivity test

This runbook retests the existing lab without changing its routes, NSGs, VPN configuration, or route-map association. It verifies the Hub A-only OCI route propagation design as well as end-to-end traffic. The OCI endpoint is an Azure-hosted simulator connected to Hub A by site-to-site VPN, not a real OCI network.

See the [solution architecture](architecture.md) for the topology and routing design.

The four-VM lab was deployed and verified on 2026-11-18; see the [verification record](../vWAN-RouteMap-PoC-Backlog.md#restricted-hub-a-verification-2026-11-18).

The lab uses resource group `rg-vwan-oci-5387083d` in East US 2. VM A and restricted `vm-a-no-oci` connect through Hub A, VM B through Hub B, and `vm-oci` is the simulator. The test starts new TCP connections on **both ports 22 and 30289** in each direction:

| Source | Destination | Expected on each port |
|---|---|---|
| VM A | Simulator | Connected |
| Simulator | VM A | Connected |
| VM A no OCI | Simulator | Not connected |
| Simulator | VM A no OCI | Not connected |
| VM B | Simulator | Not connected |
| Simulator | VM B | Not connected |

## Prerequisites

- Open PowerShell 7 on Windows in the repository root, the folder containing `README.md` and `scripts`.
- Install Azure CLI, Python 3, and the Azure CLI `virtual-wan` extension. Python 3 must also be available on all four lab VMs.
- Sign in to Azure CLI for the lab tenant and subscription. You need permission to read the networking resources, query effective routes and NSGs, and run Azure VM Run Command on all four VMs. Reader access alone may not grant these actions.
- The lab, both VPN links, and VMs `vm-a`, `vm-a-no-oci`, `vm-b`, and `vm-oci` must be available. The VMs need a working Azure VM agent. They have no public IP addresses; no SSH key is needed for this test.
- Use an access-controlled evidence directory on encrypted storage. The existing lab's `.azure\vwan-oci-5387083d\evidence` directory is git-ignored; on another workstation, create a protected directory and set `$EvidenceDir` to that path. Evidence contains network details and must not be committed or shared without review.

Testing does not require `azd`, Terraform, or the VPN pre-shared key. The collector uses Azure VM Run Command to execute short TCP probes inside the VMs.

## 1. Select the lab and check prerequisites

In the repository root, enter the tenant and subscription IDs for the deployed lab:

```powershell
$TenantId = Read-Host 'Lab tenant ID'
$SubscriptionId = Read-Host 'Lab subscription ID'
$ResourceGroup = 'rg-vwan-oci-5387083d'
# Change this path if using a different protected directory.
$EvidenceDir = Join-Path (Get-Location) '.azure\vwan-oci-5387083d\evidence'

if (-not (Test-Path -LiteralPath '.\scripts\Collect-Evidence.ps1' -PathType Leaf)) {
    throw 'Open PowerShell in the repository root.'
}
if (-not (Test-Path -LiteralPath $EvidenceDir -PathType Container)) {
    throw 'Create a protected evidence directory and set $EvidenceDir to its path.'
}
```

If you are not already signed in, run `az login --tenant $TenantId`. Then verify the selected subscription and tenant:

```powershell
$AccountJson = az account show --subscription $SubscriptionId --output json
if ($LASTEXITCODE -ne 0) { throw 'Azure sign-in or subscription lookup failed.' }
$Account = $AccountJson | ConvertFrom-Json
if ($Account.id -ne $SubscriptionId -or $Account.tenantId -ne $TenantId) {
    throw 'The subscription or tenant does not match the lab.'
}
$Account | Select-Object name, id, tenantId
```

Check the CLI extension and VM power states:

```powershell
az extension show --name virtual-wan --output table
az vm list -d --resource-group $ResourceGroup --subscription $SubscriptionId `
    --query "[].{Name:name,Power:powerState}" --output table
```

If the extension is missing, install it with `az extension add --name virtual-wan --yes`. Confirm all four lab VMs show `VM running`; stop and contact the lab owner if they do not. Check the evidence directory's permissions, for example with `icacls $EvidenceDir`.

## 2. Collect connectivity and configuration evidence

Run the collector once. It may take several minutes. The timestamped filename avoids overwriting the original baseline:

```powershell
$Timestamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$EvidenceFile = Join-Path $EvidenceDir "recheck-$Timestamp.json"
if (Test-Path -LiteralPath $EvidenceFile) { throw 'Evidence file already exists.' }

.\scripts\Collect-Evidence.ps1 -ResourceGroup $ResourceGroup `
    -SubscriptionId $SubscriptionId -EvidenceFile $EvidenceFile
```

The script queries VPN status, routes, route maps, and effective NSG rules. It also checks local listeners and runs the twelve TCP tests from the VMs. Do **not** use `-SkipConnectivity` for this procedure. If the script reports an error, stop: it can still write a partial JSON file with `complete` set to `false`. Azure returned empty connection-level effective-route lists during the recorded test, including for approved VNet A; an empty response alone does not prove a route is absent. Inspect the hub tables and NIC effective routes independently.

## 3. Check the twelve TCP results

The collector prints the acceptance table. To inspect it again:

```powershell
$Evidence = Get-Content -Raw -LiteralPath $EvidenceFile | ConvertFrom-Json
$Evidence | Select-Object collectedAtUtc, complete
$Evidence.acceptance | Format-Table source, target, port, expected, actual, passed -AutoSize
$Evidence.probes | Where-Object { $_.target -eq 'local' } |
    Format-Table source, port, connected -AutoSize

if (-not $Evidence.complete -or @($Evidence.acceptance).Count -ne 12 -or
    @($Evidence.acceptance | Where-Object { -not $_.passed }).Count -ne 0) {
    throw 'The connectivity check is incomplete or did not match expectations.'
}
```

All twelve acceptance rows should show `passed = True`. For the restricted VNet and VM B rows, `actual = not connected` is the expected result; it is not a failure. The eight local listener checks should all show `connected = True`.

A negative test needs more than a timeout. Confirm both restricted VMs' destination listeners are not limited to loopback:

```powershell
foreach ($vm in @('vm-a-no-oci', 'vm-b')) {
    Write-Host "Listeners on $vm"
    az vm run-command invoke --resource-group $ResourceGroup --name $vm `
        --subscription $SubscriptionId --command-id RunShellScript `
        --scripts 'ss -lnt' --query 'value[0].message' --output tsv
    if ($LASTEXITCODE -ne 0) { throw "Listener check failed on $vm." }
}
```

Look for listeners on `0.0.0.0:22` and `0.0.0.0:30289`, or on each VM's private IP. If a listener exists only on `127.0.0.1`, the inbound negative test is inconclusive until the listener is corrected and the test is rerun.

## 4. Check the VPN and isolation controls

`complete = True` confirms the collection and TCP expectations, but it does not by itself validate every VPN or routing setting. Inspect both sides of both VPN links:

```powershell
@(
    $Evidence.vpnConnections.'hub-primary'.links
    $Evidence.vpnConnections.'hub-secondary'.links
) | Format-Table name, status, bgp, protocol

@(
    $Evidence.vpnConnections.'simulator-primary'
    $Evidence.vpnConnections.'simulator-secondary'
) | Format-Table name, status, bgp
```

Both hub links and both simulator connections should show `Connected`; BGP should be `False` and the hub links should show `IKEv2`. The evidence also includes each side's IPsec policy.

Check the configured VPN site and simulator-side static destinations:

```powershell
foreach ($endpoint in @('primary', 'secondary')) {
    Write-Host "$endpoint VPN-site prefixes:"
    $Evidence.vpnSites.$endpoint.addressSpace.addressPrefixes
    Write-Host "$endpoint simulator-side Azure destinations:"
    $Evidence.localGateways.$endpoint.addressSpace.addressPrefixes
}
```

Each VPN site should contain `10.29.0.0/22`. Each simulator-side local gateway should contain VNet A's `10.110.0.0/24`, not `10.120.0.0/24` or `10.130.0.0/24`.

Check the VNet route-table association and map:

```powershell
Write-Host 'VNet A associated route table (should end in /hubRouteTables/rt-oci-a):'
$Evidence.hubConnections.a.routingConfiguration.associatedRouteTable.id
Write-Host 'VNet B outbound map:'
$Evidence.hubConnections.b.routingConfiguration.outboundRouteMap.id
Write-Host 'Restricted Hub A association, propagation and outbound map:'
$Evidence.hubConnections.'a-no-oci'.routingConfiguration | ConvertTo-Json -Depth 10
$Evidence.hubARouteMap.rules | ConvertTo-Json -Depth 10
$Evidence.routeMap.rules | ConvertTo-Json -Depth 10
```

The restricted Hub A connection should associate with `hub-a/hubRouteTables/defaultRouteTable`, propagate to `rt-oci-a` / `hub-a-oci` rather than `default`, and use `hub-a/routeMaps/RM-DROP-OCI`. The VNet B map association should end in `hub-b/routeMaps/RM-DROP-OCI`. Each rule should match `10.29.0.0/22` with `Contains`, action `Drop`, and next step `Terminate`.

Verify both Hub A VPN connections remain associated with Hub A's Default route table, but propagate to the Hub A-only `rt-oci-a` table and label. Neither connection should propagate to the shared `default` label:

```powershell
foreach ($endpoint in @('primary', 'secondary')) {
    $routing = $Evidence.vpnConnections."hub-$endpoint".routing
    [pscustomobject]@{
        Endpoint       = $endpoint
        Associated      = $routing.associatedRouteTable.id
        PropagatedIds   = ($routing.propagatedRouteTables.ids.id -join ', ')
        PropagatedLabels = ($routing.propagatedRouteTables.labels -join ', ')
    }
}
```

The associated route-table ID should end in `hub-a/hubRouteTables/defaultRouteTable`. Each propagated table ID should end in `hub-a/hubRouteTables/rt-oci-a`, and the label should be `hub-a-oci` (not `default`). Confirm both VPN links still report `Connected`.

Inspect the effective NSG denies for both restricted VMs and the simulator:

```powershell
foreach ($vm in @('a-no-oci', 'b', 'oci')) {
    Write-Host "Deny rules for vm-$vm"
    $Evidence.effectiveNsgs.$vm.value.effectiveSecurityRules |
        Where-Object { $_.name -like '*deny-b-oci-*' -or $_.name -like '*deny-a-no-oci-*' } |
        Format-Table name, direction, access, protocol, priority, `
            sourceAddressPrefix, destinationAddressPrefix -AutoSize
}
```

Each restricted VM should have inbound and outbound `Deny` rules for the simulator, and the simulator should have both directions denied for each restricted prefix, covering all protocols. Inspect the remaining effective rules and routes as well if there are additional policies or alternate paths.

## 5. Check routes and compare with the baseline

Inspect the exact simulator prefix in each VM's effective routes:

```powershell
foreach ($vm in @('a', 'a-no-oci', 'b')) {
    Write-Host "Simulator route for vm-$vm"
    $Evidence.nicRoutes.$vm.value |
        Where-Object { $_.addressPrefix -contains '10.29.0.0/22' } |
        Format-Table addressPrefix, nextHopType, state
}

$Evidence.hubRoutes.b.defaultTable.value |
    Where-Object { $_.addressPrefixes -contains '10.29.0.0/22' } |
    Format-Table addressPrefixes, nextHopType

Write-Host 'Hub A OCI-only route table (should contain the simulator prefix):'
$Evidence.hubRoutes.a.ociRouteTable.value |
    Where-Object { $_.addressPrefixes -contains '10.29.0.0/22' } |
    Format-Table addressPrefixes, nextHopType

Write-Host 'Hub A Default table (should not contain the simulator prefix):'
$Evidence.hubRoutes.a.defaultTable.value |
    Where-Object { $_.addressPrefixes -contains '10.29.0.0/22' } |
    Format-Table addressPrefixes, nextHopType

Write-Host 'Restricted Hub A prefix in the approved table (expected) and Default (not expected):'
foreach ($table in @('ociRouteTable', 'defaultTable')) {
    Write-Host "Hub A $table"
    $Evidence.hubRoutes.a.$table.value |
        Where-Object { $_.addressPrefixes -contains '10.120.0.0/24' } |
        Format-Table addressPrefixes, nextHopType
}
```

Expected: Hub A's `rt-oci-a` contains `10.29.0.0/22` via `VPN_S2S_Gateway` and `10.120.0.0/24` via the restricted connection; Hub A Default contains neither prefix, and Hub B Default does not contain the OCI prefix. VM A has an active OCI route via `VirtualNetworkGateway`; neither restricted VM has a usable route to the simulator through a gateway or appliance. The exact-prefix display above does not detect more-specific or broader routes, so inspect all effective routes for ranges covering both prefixes. A broad route with `nextHopType = None` is not a forwarding path; record it rather than treating it as a learned OCI route.

If the original **map-unassociated** `before.json` exists in the protected evidence directory, compare it with the new snapshot:

```powershell
$Baseline = Join-Path $EvidenceDir 'before.json'
if (-not (Test-Path -LiteralPath $Baseline -PathType Leaf)) {
    throw 'No map-unassociated baseline is available; route-map comparison is not verified.'
}
python .\scripts\compare_routes.py $Baseline $EvidenceFile
if ($LASTEXITCODE -ne 0) { throw 'The route comparison failed.' }
```

The comparison reports whether VM B's exact-prefix route disappeared, but the current design changes propagation as well as keeping the VNet B route map. It therefore does **not** isolate the map's effect. Treat the current Hub A/Hub B effective-route checks above as the propagation test, and review broader routes separately. **Read the outcome:** an `inconclusive` or unchanged result is not proof of filtering even if the command exits successfully.

If there is no suitable baseline, obtain the original protected snapshot from the lab owner or mark the map comparison **not verified**. Do not remove the map or change the deployed lab merely to create a baseline without a reviewed plan and approval.

## Troubleshooting and interpretation

| Observation | What to check |
|---|---|
| Azure CLI authorization or Run Command error | Tenant, subscription, permissions, VM power state, and VM agent health. |
| A-to-simulator test fails | Both VPN links, static routes, effective routes/NSGs, and the listeners on the destination. |
| A B-to-simulator test connects | Treat as a failure; inspect effective NSGs, route-map association, more-specific and broader routes, and simulator-side static routes. |
| B test times out but a listener is missing or loopback-only | Mark the result inconclusive; correct the listener with the lab owner's approval and rerun. |
| The comparator reports no matching baseline route | The historical before/after comparison is inconclusive; confirm that the baseline came from the same lab before the map was associated. |

The NSG denies and the simulator's A-only static routes also restrict B, including before the map is associated. A timeout does **not** prove that the route map alone blocked packets. The tests cover only the two TCP ports listed above; they do not validate real OCI DRG or firewall behavior, VPN-connection route maps, or failover.

Keep the evidence private. Use this template to record a redacted summary:

| Item | Result |
|---|---|
| Test date and time (UTC) | |
| TCP 22 and 30289 in both directions for A, A no OCI, and B | |
| Primary and secondary VPN link status | |
| Route-map comparison and NSG checks | |
| Failures, blocked checks, or limitations | |

The previous lab results are in the [backlog](../vWAN-RouteMap-PoC-Backlog.md#lab-verification-2026-11-17). The lab incurs ongoing charges; do not delete it without the owner's approval.
