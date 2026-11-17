#!/usr/bin/env python3
"""Probe TCP listeners from a private test VM."""

import json
import socket
import sys

PORTS = (22, 30289)


def probe(target, host, port):
    result = {"target": target, "host": host, "port": port, "connected": False}
    try:
        with socket.create_connection((host, port), timeout=8):
            result["connected"] = True
    except OSError as exc:
        result["error"] = str(exc)
    return result


def main(args):
    if not args or len(args) % 2:
        raise ValueError("Provide one or more target-name and IP-address pairs.")

    for target, host in zip(args[::2], args[1::2]):
        for port in PORTS:
            print("POC_RESULT=" + json.dumps(probe(target, host, port), separators=(",", ":")))


if __name__ == "__main__":
    main(sys.argv[1:])
