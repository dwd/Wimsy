#!/usr/bin/env bash
# Remove all qdiscs and restore normal networking.
# Usage: sudo ./clear-netem.sh [iface]

IFACE="${1:-wlp2s0}"

set -e

echo "[+] Clearing qdiscs"
tc qdisc del dev "$IFACE" root 2>/dev/null || true
tc qdisc del dev "$IFACE" ingress 2>/dev/null || true
tc qdisc del dev ifb0 root 2>/dev/null || true
ip link set ifb0 down 2>/dev/null || true

echo "[+] Network restored."
