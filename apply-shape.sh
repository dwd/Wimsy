#!/usr/bin/env bash
set -euo pipefail

# IFACE="${1:?Interface required}"
BW="${1:?Bandwidth required (e.g. 10mbit)}"
LAT="${2:?Latency required (e.g. 50ms)}"
LOSS="${3:?Loss required (e.g. 1%)}"

source shape-cfg.sh

echo "[*] Loading IFB module"
modprobe ifb || true
ip link add ifb0 type ifb 2>/dev/null || true
ip link set ifb0 up

echo "[*] Clearing old qdiscs"
tc qdisc del dev "$IFACE" root 2>/dev/null || true
tc qdisc del dev "$IFACE" ingress 2>/dev/null || true
tc qdisc del dev ifb0 root 2>/dev/null || true

###############################################
# OUTBOUND SHAPING (egress)
###############################################

echo "[*] Setting outbound shaping on $IFACE"

tc qdisc add dev "$IFACE" root handle 1: htb default 10
tc class add dev "$IFACE" parent 1: classid 1:10 htb rate "$BW"

tc qdisc add dev "$IFACE" parent 1:10 handle 10: netem delay "$LAT" loss "$LOSS"

# Match IPv6 UDP/5224 → remote IPv6
tc filter add dev "$IFACE" protocol ipv6 parent 1: prio 1 u32 \
    match ip6 protocol 17 0xff \
    match ip6 dport "$PORT" 0xffff \
    match ip6 dst "$IPV6" \
    flowid 1:10

# Match IPv4 UDP/5224 → remote IPv4
tc filter add dev "$IFACE" protocol ip parent 1: prio 2 u32 \
    match ip protocol 17 0xff \
    match ip dport "$PORT" 0xffff \
    match ip dst "$IPV4" \
    flowid 1:10

###############################################
# INBOUND SHAPING (ingress → IFB)
###############################################

echo "[*] Redirecting ingress to IFB"

tc qdisc add dev "$IFACE" ingress
tc filter add dev "$IFACE" parent ffff: protocol all u32 \
    match u32 0 0 action mirred egress redirect dev ifb0

echo "[*] Setting inbound shaping on ifb0"

tc qdisc add dev ifb0 root handle 2: htb default 20
tc class add dev ifb0 parent 2: classid 2:20 htb rate "$BW"

tc qdisc add dev ifb0 parent 2:20 handle 20: netem delay "$LAT" loss "$LOSS"

# Match IPv6 UDP/5224 ← remote IPv6
tc filter add dev ifb0 protocol ipv6 parent 2: prio 1 u32 \
    match ip6 protocol 17 0xff \
    match ip6 sport "$PORT" 0xffff \
    match ip6 src "$IPV6" \
    flowid 2:20

# Match IPv4 UDP/5224 ← remote IPv4
tc filter add dev ifb0 protocol ip parent 2: prio 2 u32 \
    match ip protocol 17 0xff \
    match ip sport "$PORT" 0xffff \
    match ip src "$IPV4" \
    flowid 2:20

echo "[*] Done. Active shaping:"
tc -s qdisc show dev "$IFACE"
tc -s qdisc show dev ifb0
