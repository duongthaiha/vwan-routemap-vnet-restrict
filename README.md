# Virtual WAN to simulated OCI PoC

This lab creates one Standard Virtual WAN with two hubs. VNet A and the restricted VNet `vnet-a-no-oci` connect to Hub A; VNet B connects to Hub B. Each has a private VM. A separate Azure VNet represents OCI and connects **to Hub A's VPN gateway over site-to-site IPsec**, not by VNet peering. VNet A and the simulator should reach each other; the restricted VNet and VNet B should not reach the simulator.

The VPN uses static routes and disables BGP. Both VPN sides use IKEv2, AES256/SHA384/ECP384 for IKE, and GCMAES256/ECP384 with a 3600-second lifetime for IPsec. The Azure simulator uses an active-active `VpnGw1AZ`, two VPN sites, and two local network gateways as described in [Microsoft's gateway-to-Virtual-WAN guidance](https://learn.microsoft.com/en-us/azure/virtual-wan/connect-virtual-network-gateway-vwan). This differs from the customer's single-CPE, Instance0-only configuration; it does not validate OCI DRG, OCI Network Firewall, or that configuration's failover.

The simulator's route is scoped to a Hub A-only custom route table so the Default tables do not learn it. VNet A uses that table; both the restricted VNet connection and VPN connections use Hub A's Default table. The restricted VNet propagates its own prefix to the custom table, not to the VPN-associated Default table. Outbound route maps on the restricted Hub A and Hub B connections and independent NSG denies remain defense in depth. Route maps filter routes, not packets; inspect effective routes and test both directions.

See the [solution architecture](docs/architecture.md) for the topology, routing, safeguards, and limitations.

## Prerequisites

- Azure CLI, Azure Developer CLI (`azd`), Terraform 1.7 or later, Python 3, and PowerShell 7.
- Sign in to **both** `az` and `azd` for the intended tenant and subscription. Install the CLI extension used for evidence collection: `az extension add --name virtual-wan --yes`.
- Permission and quota for a Standard Virtual WAN, two hubs, two VPN gateways, public IPs, four VMs, and related networking. Gateway creation can take an hour or more; quota and SKU availability do not reserve capacity.
- An RSA SSH public key for the VMs and a securely managed 32–128-character IPsec pre-shared key (PSK). The VMs have no public IPs; the VPN gateways require public IPs.
- Check that the [example prefixes](vWAN-RouteMap-PoC-Backlog.md#example-address-plan) do not overlap with any network reachable from the lab.

## Configure

From the repository root, create a unique AZD environment. Substitute your approved subscription, location, owner, expiry date, and public-key path:

```powershell
azd env new vwan-oci-example --no-prompt
azd env set AZURE_SUBSCRIPTION_ID <subscription-id>
azd env set AZURE_LOCATION eastus2
azd env set POC_OWNER <owner>
azd env set POC_EXPIRES_ON 2026-12-01
azd env set POC_ENABLE_B_ROUTE_MAP false
$env:TF_VAR_ssh_public_key = (Get-Content -Raw "$HOME\.ssh\id_rsa.pub").Trim()
```

The expiry is an informational tag, not an automatic deletion schedule. AZD stores Terraform state and saved plans under `.azure\<environment>\infra`; **both contain the PSK in plaintext**. This directory is git-ignored, not encrypted. Before provisioning, restrict the environment directory to the operator and SYSTEM, and keep it on encrypted storage:

```powershell
$environmentPath = Join-Path (Get-Location) '.azure\vwan-oci-example'
$sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
icacls $environmentPath /grant:r "*${sid}:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F'
icacls $environmentPath /inheritance:r
icacls $environmentPath /remove:g '*S-1-5-11' '*S-1-5-32-545' '*S-1-5-32-544'
icacls $environmentPath
```

The simulator gateway public IPs ignore changes to `ip_tags` so Azure Policy can manage those tags without Terraform replacing the IPs.

Check the commands succeed and inspect the resulting ACL for any other unexpected grants; remove them before provisioning. Also inspect the private key's ACL, since `ssh-keygen` may set explicit permissions independently of its parent directory. Back up the protected state securely; use an encrypted, access-controlled remote backend before sharing the deployment or using CI. Do not commit the state, plan, VPN configuration downloads, PSK, or private SSH key. Supply the PSK to Terraform through the current process rather than `azd env set`:

```powershell
$securePsk = Read-Host 'VPN pre-shared key' -AsSecureString
$env:TF_VAR_vpn_psk = [System.Net.NetworkCredential]::new('', $securePsk).Password
```

Retain the same PSK in a secure secret store for later updates. Remove it from the shell when finished with `Remove-Item Env:\TF_VAR_vpn_psk`. Set the public-key environment variable again for future provisioning sessions.

Azure does not return the vWAN link PSKs, so Terraform ignores changes to those fields after creation to avoid resetting the tunnels on every plan. To rotate the PSK, coordinate both VPN sides and temporarily remove that lifecycle ignore while applying the new key; review the plan before applying and restore the ignore afterward.

## Deploy and collect evidence

First deploy with the route map **unassociated** to collect a baseline. B↔OCI NSG denies and the simulator's A-only return routes remain active during this phase:

```powershell
azd provision --preview
azd provision
.\scripts\Collect-Evidence.ps1 -ResourceGroup rg-vwan-oci-example `
  -SubscriptionId <subscription-id> -EvidenceFile .azure\vwan-oci-example\evidence\before.json
```

Check both VPN connections and the baseline routes before proceeding. Associate the route map and collect the same evidence again:

```powershell
azd env set POC_ENABLE_B_ROUTE_MAP true
azd provision --preview
azd provision
.\scripts\Collect-Evidence.ps1 -ResourceGroup rg-vwan-oci-example `
  -SubscriptionId <subscription-id> -EvidenceFile .azure\vwan-oci-example\evidence\after.json
python .\scripts\compare_routes.py .azure\vwan-oci-example\evidence\before.json `
  .azure\vwan-oci-example\evidence\after.json
```

Evidence includes VPN/site configuration and route propagation, Hub A's OCI route table and Default route table, both restricted VNet connections, NIC routes, effective NSG rules, route maps, and new TCP connections on ports 22 and 30289 from each source. Local listener checks prevent a stopped service from being counted as network isolation. For a blocked inbound test, also inspect `ss -lnt` via Run Command on both restricted VMs to confirm that their listeners bind to a non-loopback address. Use `-SkipConnectivity` to collect routing-only evidence. The comparison script reports matching and broader routes; inspect next hops, more-specific routes, route-map association, and both directions before concluding what enforced isolation. Because the route-propagation configuration is also changing, a before/after comparison does not isolate the route map's effect. The Azure simulator cannot establish how route maps behave on an actual OCI DRG.

For step-by-step instructions to retest the deployed lab, see the [connectivity test runbook](docs/testing-vwan-oci-poc.md).

The [four-VM verification record](vWAN-RouteMap-PoC-Backlog.md#restricted-hub-a-verification-2026-11-18) includes the observed connectivity matrix, routes, and limitations. Evidence files contain network configuration details and should remain access-controlled and outside the repository.

## Cost and cleanup

The hubs, VPN gateways, public IPs, and VMs incur ongoing Azure charges. Preserve any needed redacted evidence and protected Terraform state, then remove the isolated lab only when its owner explicitly approves cleanup. No automatic deletion is configured.
