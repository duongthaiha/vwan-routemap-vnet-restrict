# Simplified vWAN Route-Map PoC Backlog

## Goal

Build an isolated Azure Virtual WAN lab with two hubs and a simulated OCI network. VNet A and the simulator can communicate in both directions. The restricted Hub A VNet and VNet B cannot communicate with the simulator in either direction.

The OCI side is an Azure VNet and VPN endpoint connected to the vWAN hub by site-to-site IPsec. It simulates a remote OCI network; it is not connected to a real OCI tenancy. The supplied runbook uses static routing with BGP disabled. The PoC uses that as its baseline. It does not use FastConnect or ExpressRoute, and does not reproduce the OCI DRG or Network Firewall. See [README.md](README.md) for deployment and evidence collection.

```text
 VNet A / VM A        Restricted VNet A / VM A no OCI       VNet B / VM B
        |                         |                                 |
        +----------------------- Hub A --- Virtual WAN ---------- Hub B
                                  |
                            S2S VPN (lab)
                                  |
                      Azure simulator / VM OCI
```

## Example address plan

Use non-overlapping prefixes and confirm they do not conflict with the sandbox.

| Network | Example prefix |
|---|---|
| Hub A | `10.100.0.0/23` |
| Hub B | `10.100.2.0/23` |
| VNet A | `10.110.0.0/24` |
| Restricted Hub A VNet | `10.120.0.0/24` |
| VNet B | `10.130.0.0/24` |
| Simulated OCI VNet | `10.29.0.0/22` |

## Backlog

1. **Prepare an isolated sandbox.** Confirm subscription permissions, policy, quota, supported regions, and cost. Use only PoC resources; do not connect to or change existing customer networks. Tag resources with owner and expiry, protect credentials, and obtain approval before deployment.
2. **Deploy the vWAN.** Create one Standard Virtual WAN with Hub A and Hub B. Connect VNet A and the separate restricted `vnet-a-no-oci` to Hub A, and VNet B to Hub B, with one test VM in each VNet. Add a Hub A-only custom route table and label for the simulator route; keep branch VPN connections associated with Hub A's Default table.
3. **Deploy the static VPN simulator.** Create an Azure VNet with a workload subnet, a gateway subnet, a workload VM, and an Azure VPN Gateway acting as the remote OCI VPN endpoint. Connect it to Hub A's site-to-site VPN gateway, not through a VNet-to-hub connection or VNet peering. Configure static routing and disable BGP. Set the simulator VNet prefix as the VPN sites' private address space and configure VNet A only as a static route on the simulator side. Disable default-route propagation. Match the runbook's IKEv2/IPsec policy: IKE AES-256-CBC, SHA2-384, DH group 20; IPsec AES-256-GCM for encryption and integrity, PFS group 20, 3600-second SA lifetime. Protect the PSK outside the repo. Microsoft's Azure gateway-to-vWAN topology requires an active-active simulator gateway, two VPN sites, and two local network gateways. This differs from the runbook's single-CPE, Instance0-only arrangement and does not validate its failover behavior. Verify tunnel status and static/effective routes before route-map testing; do not expect BGP peers.
4. **Scope OCI route propagation to Hub A.** Keep both Hub A VPN connections associated with Hub A's Default route table, but propagate their learned OCI routes only to a Hub A custom route table labeled `hub-a-oci`. Associate VNet A with that custom table so it can reach OCI. Continue propagating VNet A's prefix to Hub A's Default table for the VPN return path. Do not propagate the OCI prefix to the shared `default` label; Hub B's Default table should not learn it. Configure both VPN connections consistently.
5. **Keep a per-VNet route-map safeguard.** Create `RM-DROP-OCI` in each hub and apply it **outbound** to each restricted VNet connection, matching route prefixes **Contains** `10.29.0.0/22` with action **Drop** and next step **Terminate**. Do not apply it to approved VNet A. Associate the restricted Hub A VNet with Hub A Default, and propagate its prefix only to `rt-oci-a`, not the VPN's associated Default table. Route maps are defense in depth; scoped propagation keeps the OCI prefix out of both Default tables.
6. **Add traffic safeguards.** Route maps filter route advertisements; they are not packet firewalls. Add narrowly scoped NSG deny rules between each restricted VNet and `10.29.0.0/22` in both directions. On the simulator, allow only VNet A's prefix in its static routes and restrict the test ports with NSGs. Mirror the runbook's test services (TCP 22 and TCP 30289). The OCI runbook also routes both directions through an OCI Network Firewall; the Azure simulator uses static routes and NSGs instead and does not prove OCI firewall behavior. Route maps on VNet connections apply to the whole VNet; if only selected subnets within a VNet require OCI access, add a separate subnet-level design. Check effective routes and security rules for alternate, static, default, aggregate, or more-specific routes that could bypass the intended boundary.
7. **Test and record evidence.** Verify both VPN tunnels as configured, static route entries, VPN route propagation, route-map associations, hub and VM effective routes, and effective NSG rules. Do not expect BGP health or dynamic route advertisements. Confirm the OCI prefix is in Hub A's `rt-oci-a` and VNet A's effective routes, but absent from Hub A Default and Hub B Default; confirm VNet A's prefix remains in Hub A Default for return traffic. Verify the restricted Hub A prefix is absent from Hub A Default, and the simulator's static routes omit both restricted VNets. Run the six directional tests below through Run Command on the private VMs. For negative tests, retain route and NSG evidence; a timeout alone does not prove isolation. Mark tests that could not be run as BLOCKED, with a reason.
8. **Clean up.** Save redacted test results and configuration, then delete the PoC resources only after the owner explicitly approves cleanup.

## Acceptance tests

Use TCP 22 for the VM reachability checks and TCP 30289 for the simulated OCI workload (plus ICMP if enabled). Initiate a new connection from the source shown in each row.

| Source | Destination | Expected result |
|---|---|---|
| VM A | VM OCI | Connects |
| VM OCI | VM A | Connects |
| VM A no OCI | VM OCI | Blocked |
| VM OCI | VM A no OCI | Blocked |
| VM B | VM OCI | Blocked |
| VM OCI | VM B | Blocked |

VNet A-to-VNet B connectivity is not part of this PoC's acceptance criteria. Confirm the actual VPN-site and simulator static routes as well as effective routes. `Contains` matches the specified prefix and more-specific routes, but not broader aggregates. Record separately whether VPN route maps affect the static routes; do not report static route configuration as dynamic advertisement filtering.

## Lab verification (2026-11-17)

The lab in `rg-vwan-oci-5387083d` in East US 2 was tested before and after associating the route map. Evidence collection started at 18:02 UTC and 18:35 UTC, respectively; a live recheck with the map enabled started at 21:53 UTC. Both VPN links were connected, with BGP disabled and the configured IKEv2/IPsec policy on both sides.

Each cell below shows the observed results for new connections on TCP 22 and TCP 30289, respectively. Both listeners were checked locally on all three VMs. During the recheck, `ss -lnt` also confirmed that VM B's listeners were bound to `0.0.0.0`, not just loopback.

| Source to destination | Expected | Before map | After map | 21:53 recheck |
|---|---|---|---|---|
| VM A to simulator | Connect | Connected / Connected | Connected / Connected | Connected / Connected |
| Simulator to VM A | Connect | Connected / Connected | Connected / Connected | Connected / Connected |
| VM B to simulator | Block | Timed out / Timed out | Timed out / Timed out | Timed out / Timed out |
| Simulator to VM B | Block | Timed out / Timed out | Timed out / Timed out | Timed out / Timed out |

| Route observation for `10.29.0.0/22` | Before map | After map | 21:53 recheck |
|---|---|---|---|
| VM A effective route | `VirtualNetworkGateway` | `VirtualNetworkGateway` | `VirtualNetworkGateway` |
| VM B effective route | `VirtualNetworkGateway` | No active matching route | No active matching route |
| Hub B Default route table | `Remote Hub` | `Remote Hub` | `Remote Hub` |

The map was unassociated for the baseline and then associated outbound on VNet B's Hub B connection. The matching route disappeared from VM B, not from Hub B's own table. Broader routes were also present and must be considered when evaluating alternate paths. Effective NSG rules deny traffic between B and the simulator, and the simulator's static routes include VNet A only; these safeguards were active even before the map. Therefore the blocked connections do **not** prove that the route map alone enforces isolation.

The protected, git-ignored evidence snapshots (`before.json`, `after.json`, and `recheck-20261117-2153Z.json`) are in `.azure\vwan-oci-5387083d\evidence`; see [README.md](README.md#deploy-and-collect-evidence) to reproduce them. These tests cover the two TCP ports above, not every protocol or port, and do not validate a real OCI DRG, OCI Network Firewall, VPN-connection route-map behavior, or failover.

The lab remains deployed and incurs charges; cleanup requires owner approval.

## Scoped route propagation verification (2026-11-18)

The Hub A-only route propagation update was applied to `rg-vwan-oci-5387083d` in East US 2. Terraform reported 1 resource added, 3 changed, and 0 destroyed. The new `rt-oci-a` table uses the `hub-a-oci` label; both Hub A VPN connections remain associated with Hub A Default and propagate to `rt-oci-a`. VNet A is associated with `rt-oci-a`, and its prefix continues to propagate to Hub A Default for the VPN return path.

The complete protected snapshot `post-route-isolation-20261118T002343Z.json` is in `.azure\vwan-oci-5387083d\evidence`. Both VPN links and both simulator-side connections reported `Connected`, with BGP disabled. Each VPN site advertised `10.29.0.0/22`; each simulator-side local gateway had a static return route to VNet A (`10.110.0.0/24`) only.

| Route observation for `10.29.0.0/22` | Observed result |
|---|---|
| Hub A `rt-oci-a` and VNet A effective routes | Present via `VPN_S2S_Gateway` / `VirtualNetworkGateway` |
| Hub A Default and Hub B Default route tables | No overlapping route |
| Hub B VNet connection and VM B usable gateway route | No OCI route; the only overlapping NIC route was broader `10.0.0.0/8` with next hop `None`, which is not a path to the simulator |
| VNet B route-map safeguard | `RM-DROP-OCI` remains associated outbound on the Hub B VNet connection |

All eight TCP probes passed: A↔simulator connected on ports 22 and 30289; B↔simulator could not connect on either port in either direction. All six local listener checks passed, and `ss -lnt` confirmed VM B listens on `0.0.0.0:22` and `0.0.0.0:30289`, so the negative results are not due to loopback-only or missing services. Effective NSG deny rules between B and the simulator and the simulator's A-only static return routes remain active. The failed B probes therefore validate the combined isolation design; they do not prove that the route map alone blocked traffic.

The lab remains deployed and incurs charges; cleanup requires owner approval.

## Restricted Hub A verification (2026-11-18)

The reviewed Terraform plan was applied to the existing lab after the owner approved replacing the three existing VMs. Terraform reported 15 additions (including the three replacement VMs), no changes, and three deletions. The post-apply preview showed no managed-resource changes. Evidence collection began at 10:25 UTC and is saved in the protected, git-ignored `.azure\vwan-oci-5387083d\evidence\hub-a-restricted-20261118T102539Z.json`.

| Source to destination | TCP 22 | TCP 30289 |
|---|---|---|
| VM A to simulator | Connected | Connected |
| Simulator to VM A | Connected | Connected |
| VM A no OCI to simulator | Timed out | Timed out |
| Simulator to VM A no OCI | Timed out | Timed out |
| VM B to simulator | Timed out | Timed out |
| Simulator to VM B | Timed out | Timed out |

All 12 checks matched their expected outcomes and all eight local listener checks passed. `ss -lnt` confirmed both restricted VMs listen on `0.0.0.0` on both ports. Both hub VPN links and both simulator connections were `Connected`, with BGP disabled. Each simulator-side static gateway listed only VNet A.

Hub A's `rt-oci-a` contained the simulator prefix `10.29.0.0/22` and restricted prefix `10.120.0.0/24`; Hub A Default contained neither. Hub B Default contained no overlapping simulator route. VM A's NIC had the simulator route through `VirtualNetworkGateway`; both restricted NICs had no matching or more-specific simulator route. Their most-specific covering route was `10.0.0.0/8` with next hop `None`; a less-specific `0.0.0.0/0` Internet route also existed. Both outbound route maps and all eight bidirectional, all-protocol NSG deny rules were confirmed.

Azure returned empty effective-route lists for the Hub A VNet connections, including approved VNet A, on collection and recheck. Those empty lists alone do not prove route absence; the route observations above use the hub route tables and effective NIC routes. The timeouts establish the combined behavior of routing, NSGs, and simulator static routes, not which individual control blocked a packet. The probes cover only TCP 22 and 30289 and do not test a real OCI DRG, firewall, failover, or a workload acting as a proxy.

The lab remains deployed and incurs charges; cleanup requires owner approval.

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
