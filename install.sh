#!/usr/bin/env bash
# Installation idempotente de steamd sans paquet (fichiers dans ~/.local).
# Avec le paquet Arch (packaging/arch), utiliser plutôt makepkg -si puis steamd-setup.
set -euo pipefail
cd "$(dirname "$0")"

[[ $EUID -eq 0 ]] && { echo "Lancer en utilisateur, pas en root." >&2; exit 1; }
if pacman -Qq steamd >/dev/null 2>&1; then
    echo "Le paquet steamd est déjà installé : lancer steamd-setup." >&2; exit 1
fi

BIN="$HOME/.local/bin"
UNITS="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
SHARE="${XDG_DATA_HOME:-$HOME/.local/share}/steamd"

echo "→ scripts dans $BIN"
install -Dm755 -t "$BIN" bin/steamd-launch bin/steamd-doctor bin/steamd-session-hook bin/steamd-setup
install -Dm644 config/steamd.conf.example "$SHARE/steamd.conf.example"

echo "→ unités dans $UNITS"
mkdir -p "$UNITS"
for u in systemd/*.service; do
    sed "s|@BINDIR@|$BIN|" "$u" > "$UNITS/$(basename "$u")"
done

echo "→ règle udev uinput et chargement du module (sudo)"
sudo install -Dm644 udev/60-steamd-uinput.rules /etc/udev/rules.d/60-steamd-uinput.rules
sudo install -Dm644 udev/steamd-uinput.conf /etc/modules-load.d/steamd-uinput.conf
sudo modprobe uinput
sudo udevadm control --reload
sudo udevadm trigger --action=change --sysname-match=uinput

"$BIN/steamd-setup"
