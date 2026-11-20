#!/usr/bin/env bash
# Désinstallation idempotente de steamd installé par install.sh.
#   --remove-group    retirer l'utilisateur du groupe input
#   --disable-linger  désactiver le linger
#   --purge           supprimer aussi ~/.config/steamd
set -euo pipefail
cd "$(dirname "$0")"

[[ $EUID -eq 0 ]] && { echo "Lancer en utilisateur, pas en root." >&2; exit 1; }

BIN="$HOME/.local/bin"
UNITS="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SHARE="${XDG_DATA_HOME:-$HOME/.local/share}/steamd"

bin/steamd-setup --undo "$@"

echo "→ unités et scripts"
rm -f "$UNITS/steamd.service" "$UNITS/steamd-profiled.service"
systemctl --user daemon-reload
rm -f "$BIN/steamd-launch" "$BIN/steamd-doctor" "$BIN/steamd-setup" "$BIN/steamd-profiled" "$BIN/steamd-steamcfg" "$BIN/steamd-probe"
rm -rf "$SHARE"

echo "→ règle udev et module (sudo)"
sudo rm -f /etc/udev/rules.d/60-steamd-uinput.rules /etc/modules-load.d/steamd-uinput.conf
sudo udevadm control --reload
sudo udevadm trigger --action=change --sysname-match=uinput
echo "Désinstallé."
