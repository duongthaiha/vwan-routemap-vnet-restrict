#!/usr/bin/env python3
"""Compare VM B's effective routes before and after route-map association."""

import argparse
import ipaddress
import json


def routes_in(value):
    if isinstance(value, dict):
        prefix = value.get("addressPrefix", value.get("addressPrefixes"))
        state = value.get("state")
        if prefix is not None and (state is None or state.lower() == "active"):
            for item in prefix if isinstance(prefix, list) else [prefix]:
                try:
                    network = ipaddress.ip_network(item, strict=False)
                except (TypeError, ValueError):
                    continue
                yield network, value.get("nextHopType", "unknown")
        for child in value.values():
            if isinstance(child, (dict, list)):
                yield from routes_in(child)
    elif isinstance(value, list):
        for child in value:
            yield from routes_in(child)


def compare(before, after, simulator_prefix):
    simulator = ipaddress.ip_network(simulator_prefix, strict=True)
    observations = []
    for evidence in (before, after):
        entries = list(routes_in(evidence["nicRoutes"]["b"]))
        matching = sorted(
            {str(network) for network, _ in entries if network.version == simulator.version and network.subnet_of(simulator)}
        )
        covering = sorted(
            {f"{network} ({next_hop})" for network, next_hop in entries
             if network.version == simulator.version and simulator.subnet_of(network) and network != simulator}
        )
        observations.append({"matching": matching, "broaderRoutes": covering})

    before_matches = set(observations[0]["matching"])
    after_matches = set(observations[1]["matching"])
    if not before_matches:
        outcome = "inconclusive: no matching active route was observed before association"
    elif not after_matches:
        outcome = "matching routes disappeared after association"
    elif before_matches - after_matches:
        outcome = "some matching routes disappeared, but matching routes remain"
    else:
        outcome = "no matching route removal was observed"

    return {"outcome": outcome, "before": observations[0], "after": observations[1]}


def validate_snapshots(before, after):
    if not before.get("complete") or not after.get("complete"):
        raise ValueError("Both evidence collections must have completed successfully.")
    for field in ("subscriptionId", "resourceGroup"):
        if not before.get(field) or str(before[field]).lower() != str(after.get(field, "")).lower():
            raise ValueError(f"Evidence snapshots must have the same {field}.")

    def outbound_map(evidence):
        connection = evidence["hubConnections"]["b"]
        routing = connection.get("routingConfiguration")
        if not isinstance(routing, dict):
            raise ValueError("VNet B routing configuration is missing from the evidence.")
        return (routing.get("outboundRouteMap") or {}).get("id")

    expected_map = after["routeMap"].get("id")
    if outbound_map(before):
        raise ValueError("Baseline already has an outbound route map.")
    after_map = outbound_map(after)
    if not expected_map or not after_map or after_map.lower() != expected_map.lower():
        raise ValueError("The expected outbound route map is not confirmed in the second snapshot.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("before", help="Evidence JSON collected before map association")
    parser.add_argument("after", help="Evidence JSON collected after map association")
    parser.add_argument("--simulator-prefix", default="10.29.0.0/22")
    args = parser.parse_args()

    with open(args.before, encoding="utf-8-sig") as file:
        before = json.load(file)
    with open(args.after, encoding="utf-8-sig") as file:
        after = json.load(file)
    validate_snapshots(before, after)
    print(json.dumps(compare(before, after, args.simulator_prefix), indent=2))
    print("Inspect broader routes and route-map association separately; NSGs and return routes also affect traffic.")


if __name__ == "__main__":
    main()
