#!/usr/bin/env bash
# Réveil de l'hôte steamd. À ajouter comme jeu non-Steam (mode bureau du Deck).
MAC="AA:BB:CC:DD:EE:FF"       # MAC visée par le magic packet (le Pi relaie vers l'Ethernet du PC)
BROADCAST="255.255.255.255"
PORT=9

if command -v wakeonlan >/dev/null; then
    exec wakeonlan -i "$BROADCAST" -p "$PORT" "$MAC"
fi
exec python3 - "$MAC" "$BROADCAST" "$PORT" <<'PY'
import socket, sys
mac, bcast, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
payload = b"\xff" * 6 + bytes.fromhex(mac.replace(":", "").replace("-", "")) * 16
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    s.sendto(payload, (bcast, port))
print(f"magic packet envoyé à {mac} via {bcast}:{port}")
PY
