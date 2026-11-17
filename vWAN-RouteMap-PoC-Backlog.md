# Simplified vWAN Route-Map PoC Backlog

## Goal

Build an isolated Azure Virtual WAN lab with two hubs and a simulated OCI network. Hub A and the simulator can communicate in both directions. Hub B and the simulator cannot communicate in either direction.

The OCI side is an Azure VNet and VPN endpoint connected to the vWAN hub by site-to-site IPsec. It simulates a remote OCI network; it is not connected to a real OCI tenancy. The supplied runbook uses static routing with BGP disabled. The PoC uses that as its baseline. It does not use FastConnect or ExpressRoute, and does not reproduce the OCI DRG or Network Firewall. See [README.md](README.md) for deployment and evidence collection.

```text
 VNet A / VM A                   VNet B / VM B
        |                               |
      Hub A -------- Virtual WAN ----- Hub B
        |
   S2S VPN (lab)
        |
 Azure VNet simulating OCI / VM OCI
```

## Example address plan

Use non-overlapping prefixes and confirm they do not conflict with the sandbox.

| Network | Example prefix |
|---|---|
| Hub A | `10.100.0.0/23` |
| Hub B | `10.100.2.0/23` |
| VNet A | `10.110.0.0/24` |
| VNet B | `10.130.0.0/24` |
| Simulated OCI VNet | `10.29.0.0/22` |

## Backlog

1. **Prepare an isolated sandbox.** Confirm subscription permissions, policy, quota, supported regions, and cost. Use only PoC resources; do not connect to or change existing customer networks. Tag resources with owner and expiry, protect credentials, and obtain approval before deployment.
2. **Deploy the vWAN.** Create one Standard Virtual WAN with Hub A and Hub B. Connect VNet A to Hub A and VNet B to Hub B, with one test VM in each VNet. Use the Default route tables; do not add custom route tables or routing intent for this PoC.
3. **Deploy the static VPN simulator.** Create an Azure VNet with a workload subnet, a gateway subnet, a workload VM, and an Azure VPN Gateway acting as the remote OCI VPN endpoint. Connect it to Hub A's site-to-site VPN gateway, not through a VNet-to-hub connection or VNet peering. Configure static routing and disable BGP. Set the simulator VNet prefix as the VPN sites' private address space and configure VNet A only as a static route on the simulator side. Disable default-route propagation. Match the runbook's IKEv2/IPsec policy: IKE AES-256-CBC, SHA2-384, DH group 20; IPsec AES-256-GCM for encryption and integrity, PFS group 20, 3600-second SA lifetime. Protect the PSK outside the repo. Microsoft's Azure gateway-to-vWAN topology requires an active-active simulator gateway, two VPN sites, and two local network gateways. This differs from the runbook's single-CPE, Instance0-only arrangement and does not validate its failover behavior. Verify tunnel status and static/effective routes before route-map testing; do not expect BGP peers.
4. **Apply the per-VNet restriction.** Create a reusable `RM-DROP-OCI` route map in each hub that owns restricted VNets. Apply it **outbound** on each restricted VNet connection, matching route prefixes **Contains** `10.29.0.0/22` with action **Drop** and next step **Terminate**. For this two-hub lab, apply it to VNet B's connection in Hub B. Do not apply it to approved VNet A: its OCI route should remain advertised. Unmatched routes remain allowed, preserving existing Azure routes. Capture route state before and after applying the map.
5. **Validate static VPN route-map behavior.** Route maps process routes on connections, but this runbook has no BGP updates: OCI prefixes are configured as VPN-site address space, and Azure prefixes are configured as OCI static routes. Compare VNet B's effective routes before and after its outbound map is associated to determine whether the map filters the simulator prefix. This test does not establish how route maps on VPN connections behave. For the OCI-to-Azure direction, configure the simulator's static routes to include VNet A only, not VNet B.
6. **Add traffic safeguards.** Route maps filter route advertisements; they are not packet firewalls. Add narrowly scoped NSG deny rules between VNet B and `10.29.0.0/22` in both directions. On the simulator, allow only VNet A's prefix in its static routes and restrict the test ports with NSGs. Mirror the runbook's test services (TCP 22 and TCP 30289). The OCI runbook also routes both directions through an OCI Network Firewall; the Azure simulator uses static routes and NSGs instead and does not prove OCI firewall behavior. Route maps on VNet connections apply to the whole VNet; if only selected subnets within a VNet require OCI access, add a separate subnet-level design. Check effective routes and security rules for alternate, static, default, aggregate, or more-specific routes that could bypass the intended boundary.
7. **Test and record evidence.** Verify both VPN tunnels as configured, static route entries, route-map associations, hub and VM effective routes, and effective NSG rules. Do not expect BGP health or dynamic route advertisements. Check that VNet A retains the OCI route and that the simulator has a static route to VNet A but not VNet B. Compare VNet B's routes before and after the map; Hub B's own default route table may still contain the OCI prefix. Run the tests from VM A/B through Azure Serial Console or Run Command (the VMs have no public IP); initiate OCI-originated tests from the simulator workload VM. Record the four connectivity tests below. For negative tests, retain route and NSG evidence; a timeout alone does not prove isolation. Mark tests that could not be run as BLOCKED, with a reason.
8. **Clean up.** Save redacted test results and configuration, then delete the PoC resources only after the owner explicitly approves cleanup.

## Acceptance tests

Use TCP 22 for the VM reachability checks and TCP 30289 for the simulated OCI workload (plus ICMP if enabled). Initiate a new connection from the source shown in each row.

| Source | Destination | Expected result |
|---|---|---|
| VM A | VM OCI | Connects |
| VM OCI | VM A | Connects |
| VM B | VM OCI | Blocked |
| VM OCI | VM B | Blocked |

VNet A-to-VNet B connectivity is not part of this PoC's acceptance criteria. Confirm the actual VPN-site and simulator static routes as well as effective routes. `Contains` matches the specified prefix and more-specific routes, but not broader aggregates. Record separately whether VPN route maps affect the static routes; do not report static route configuration as dynamic advertisement filtering.

## Lab verification (2026-11-17)

In the Azure-hosted simulator lab, both VPN links connected and all four traffic directions matched the table above on TCP 22 and 30289. After the map was associated, the simulator prefix disappeared from VM B's effective routes but remained on VM A and in Hub B's Default route table. NSG denies and the simulator's A-only return routes also enforce isolation.

The lab remains deployed and incurs charges; cleanup requires owner approval. These results do not validate a real OCI DRG, firewall, or failover.

## Design references

The supplied slides are included in [`docs/references/`](docs/references/):

- [Route-map directions](docs/references/route-map-directions.png) explains inbound and outbound relative to the hub.
- [Per-hub route-map policy](docs/references/per-hub-route-map-policy.png) shows the reusable OCI drop map for restricted VNet connections and allow-list filtering at the OCI boundary.
- [Recommended pattern](docs/references/recommended-pattern.png) calls out Default routing, leaving approved VNets without the drop map, and the subnet-level scope limitation.
- [Multi-region application pattern](docs/references/multi-region-application-pattern.png) shows repeating the policy in each participating hub.

## References

- [Connect a virtual network gateway to Azure Virtual WAN](https://learn.microsoft.com/en-us/azure/virtual-wan/connect-virtual-network-gateway-vwan)
- [Tutorial: Create a site-to-site connection using Virtual WAN](https://learn.microsoft.com/en-us/azure/virtual-wan/virtual-wan-site-to-site-portal)
- [About Virtual WAN route maps](https://learn.microsoft.com/en-us/azure/virtual-wan/route-maps-about)
- [Configure Virtual WAN route maps](https://learn.microsoft.com/en-us/azure/virtual-wan/route-maps-how-to)
- [Configure a custom IPsec policy for Azure Virtual WAN](https://learn.microsoft.com/en-us/azure/virtual-wan/virtual-wan-custom-ipsec-portal)
