# Remote QUIC endpoint
IPV6="2a02:8010:300a::3"
IPV4="88.98.37.179"
PORT="5224"
IFACE=$(ip route get "$IPV4" | awk '/dev/ {for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}')

echo "[*] Using $IFACE"
