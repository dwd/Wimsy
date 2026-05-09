#!/usr/bin/env bash
set -euo pipefail

# Usage: apply-shape.sh <bandwidth> <latency> <loss>
#   e.g. apply-shape.sh 10mbit 50ms 1%
#
# Applies bandwidth/latency/loss shaping ONLY to the XMPP/QUIC flow
# (UDP/$PORT to/from $IPV4 / $IPV6) plus ICMP/ICMPv6 echo to/from
# the same host (so `ping` can be used to trivially test the shaping).
# All other traffic on $IFACE is left untouched.

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
# OUTBOUND SHAPING (egress on $IFACE)
###############################################
#
# Default class 1:1 is an UNSHAPED bypass at line rate, so unmatched
# traffic is not affected. Only filters explicitly steer traffic into
# the shaped class 1:10.

echo "[*] Setting outbound shaping on $IFACE"

tc qdisc add dev "$IFACE" root handle 1: htb default 1

# 1:1 = bypass (no rate limit, no netem)
tc class add dev "$IFACE" parent 1: classid 1:1  htb rate 10gbit ceil 10gbit

# 1:10 = shaped class for XMPP/QUIC + ICMP echo to host
tc class add dev "$IFACE" parent 1: classid 1:10 htb rate "$BW" ceil "$BW"
tc qdisc add dev "$IFACE" parent 1:10 handle 10: netem delay "$LAT" loss "$LOSS"

# --- IPv6 ---

# IPv6 UDP/$PORT → $IPV6 (XMPP/QUIC)
tc filter add dev "$IFACE" protocol ipv6 parent 1: prio 1 u32 \
    match ip6 protocol 17 0xff \
    match ip6 dport "$PORT" 0xffff \
    match ip6 dst "$IPV6" \
    flowid 1:10

# IPv6 ICMPv6 → $IPV6 (ping, for trivial testing)
# next-header 58 = ICMPv6
tc filter add dev "$IFACE" protocol ipv6 parent 1: prio 3 u32 \
    match ip6 protocol 58 0xff \
    match ip6 dst "$IPV6" \
    flowid 1:10

# --- IPv4 ---

# IPv4 UDP/$PORT → $IPV4 (XMPP/QUIC)
tc filter add dev "$IFACE" protocol ip parent 1: prio 2 u32 \
    match ip protocol 17 0xff \
    match ip dport "$PORT" 0xffff \
    match ip dst "$IPV4" \
    flowid 1:10

# IPv4 ICMP → $IPV4 (ping, for trivial testing)
tc filter add dev "$IFACE" protocol ip parent 1: prio 4 u32 \
    match ip protocol 1 0xff \
    match ip dst "$IPV4" \
    flowid 1:10

###############################################
# INBOUND SHAPING (ingress → IFB)
###############################################
#
# Only the matched flows (XMPP/QUIC + ICMP echo from the host) are
# redirected to ifb0. Everything else stays on the normal ingress path
# and is not touched by the shaper.

echo "[*] Redirecting matched ingress to IFB"

tc qdisc add dev "$IFACE" handle ffff: ingress

# IPv6 UDP/$PORT ← $IPV6 (XMPP/QUIC)
tc filter add dev "$IFACE" parent ffff: protocol ipv6 prio 1 u32 \
    match ip6 protocol 17 0xff \
    match ip6 sport "$PORT" 0xffff \
    match ip6 src "$IPV6" \
    action mirred egress redirect dev ifb0

# IPv6 ICMPv6 ← $IPV6 (ping replies / inbound echo)
tc filter add dev "$IFACE" parent ffff: protocol ipv6 prio 3 u32 \
    match ip6 protocol 58 0xff \
    match ip6 src "$IPV6" \
    action mirred egress redirect dev ifb0

# IPv4 UDP/$PORT ← $IPV4 (XMPP/QUIC)
tc filter add dev "$IFACE" parent ffff: protocol ip prio 2 u32 \
    match ip protocol 17 0xff \
    match ip sport "$PORT" 0xffff \
    match ip src "$IPV4" \
    action mirred egress redirect dev ifb0

# IPv4 ICMP ← $IPV4 (ping replies / inbound echo)
tc filter add dev "$IFACE" parent ffff: protocol ip prio 4 u32 \
    match ip protocol 1 0xff \
    match ip src "$IPV4" \
    action mirred egress redirect dev ifb0

echo "[*] Setting inbound shaping on ifb0"

# Everything that arrives on ifb0 is, by construction, the matched
# flow, so a single shaped default class is sufficient.
tc qdisc add dev ifb0 root handle 2: htb default 20
tc class add dev ifb0 parent 2: classid 2:20 htb rate "$BW" ceil "$BW"
tc qdisc add dev ifb0 parent 2:20 handle 20: netem delay "$LAT" loss "$LOSS"

echo "[*] Done. Active shaping:"
tc -s qdisc show dev "$IFACE"
tc -s qdisc show dev ifb0
