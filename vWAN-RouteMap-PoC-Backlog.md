# Simplified vWAN Route-Map PoC Backlog

## Goal

Build an isolated Azure Virtual WAN lab with two hubs and a simulated OCI network. Hub A and the simulator can communicate in both directions. Hub B and the simulator cannot communicate in either direction.

The OCI side is an Azure VNet connected by site-to-site VPN. It simulates a remote OCI network; it is not connected to a real OCI tenancy. The design slides show the production boundary as OCI FastConnect plus Azure ExpressRoute. The VPN is a lab substitute, so it validates route-map policy and traffic behavior, not ExpressRoute-specific configuration.

```text
 VNet A / VM A                   VNet B / VM B
        |                               |
      Hub A -------- Virtual WAN ----- Hub B
        |
   S2S VPN (lab)
        |
 Azure VNet simulating OCI / VM OCI
```

For the production design, the remote OCI connection is FastConnect to
ExpressRoute. The same per-VNet outbound route-map policy applies across the
participating vWAN hubs.

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
3. **Deploy the OCI simulator.** Create an Azure VNet, a workload VM, and an Azure VPN Gateway. Connect it to the site-to-site VPN gateway in Hub A. Configure a supported BGP-enabled VPN with non-overlapping address spaces and distinct supported ASNs (the simulator ASN must not be `65515`). Do not connect or peer the simulator VNet directly to either vWAN hub. Verify the tunnel and BGP session before route-map testing.
4. **Apply the per-VNet restriction.** Create a reusable `RM-DROP-OCI` route map in each hub that owns restricted VNets. Apply it **outbound** on each restricted VNet connection, matching route prefixes **Contains** `10.29.0.0/22` with action **Drop** and next step **Terminate**. For this two-hub lab, apply it to VNet B's connection in Hub B. Do not apply it to approved VNet A: its OCI route should remain advertised. Unmatched routes remain allowed, preserving existing Azure routes. Capture route state before and after applying the map.
5. **Filter the OCI boundary.** On the simulator-facing VPN connection (the lab equivalent of the production ExpressRoute boundary), configure inbound filtering so only approved OCI prefixes enter the vWAN, and outbound filtering so only approved Azure prefixes are advertised to the simulator. Validate the route-map match and default behavior against current Virtual WAN documentation before deployment; confirm unrelated routes remain intact. For production, apply these policies on the ExpressRoute connection to OCI FastConnect.
6. **Add traffic safeguards.** Route maps filter route advertisements; they are not packet firewalls. Add narrowly scoped NSG deny rules between VNet B and `10.29.0.0/22` in both directions. Allow the chosen test port between VNet A and the simulator, and configure guest firewalls accordingly. Route maps on VNet connections apply to the whole VNet; if only selected subnets within a VNet require OCI access, add a separate subnet-level design. Check effective routes and security rules for alternate, static, default, aggregate, or more-specific routes that could bypass the intended boundary.
7. **Test and record evidence.** Verify VPN/BGP health, route-map associations on both hubs and the simulator boundary, hub and VM effective routes, and effective NSG rules. Confirm Hub B does not advertise OCI routes to VNet B, VNet A retains its OCI route, and the simulator learns only approved Azure prefixes. Record the four connectivity tests below. For negative tests, retain route and NSG evidence; a timeout alone does not prove isolation. Mark tests that could not be run as BLOCKED, with a reason.
8. **Clean up.** Save redacted test results and configuration, then delete the PoC resources when they are no longer needed to avoid ongoing charges.

## Acceptance tests

Start the same test service and port on each VM. Initiate a new connection from the source shown in each row.

| Source | Destination | Expected result |
|---|---|---|
| VM A | VM OCI | Connects |
| VM OCI | VM A | Connects |
| VM B | VM OCI | Blocked |
| VM OCI | VM B | Blocked |

VNet A-to-VNet B connectivity is not part of this PoC's acceptance criteria. Confirm the actual advertised prefixes: `Contains` matches the specified prefix and more-specific routes, but not broader aggregates. Also verify the approved OCI prefixes entering the vWAN and approved Azure prefixes advertised to the simulator.

## Design references

The supplied slides are included in [`docs/references/`](docs/references/):

- [Route-map directions](docs/references/route-map-directions.png) explains inbound and outbound relative to the hub.
- [Per-hub route-map policy](docs/references/per-hub-route-map-policy.png) shows the reusable OCI drop map for restricted VNet connections and allow-list filtering at the OCI boundary.
- [Recommended pattern](docs/references/recommended-pattern.png) calls out Default routing, leaving approved VNets without the drop map, and the subnet-level scope limitation.
- [Multi-region application pattern](docs/references/multi-region-application-pattern.png) shows repeating the policy in each participating hub.

## References

- [Connect a virtual network gateway to Azure Virtual WAN](https://learn.microsoft.com/en-us/azure/virtual-wan/connect-virtual-network-gateway-vwan)
- [About Virtual WAN route maps](https://learn.microsoft.com/en-us/azure/virtual-wan/route-maps-about)
- [Configure Virtual WAN route maps](https://learn.microsoft.com/en-us/azure/virtual-wan/route-maps-how-to)
