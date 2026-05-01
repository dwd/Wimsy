#!/usr/bin/env bash
set -euo pipefail

source shape-cfg.sh

echo "[*] Using $IFACE"

tc qdisc del dev "$IFACE" root 2>/dev/null || true
tc qdisc del dev "$IFACE" ingress 2>/dev/null || true
tc qdisc del dev ifb0 root 2>/dev/null || true

echo "Shaping removed."
