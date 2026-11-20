#!/usr/bin/env bash
# uninstall.sh : retire ce que install.sh a ajouté. Idempotent.
#
#   ./uninstall.sh [--remove-group] [--disable-linger] [--purge] [--force]
#
#   --remove-group    retire l'utilisateur du groupe uinput, seulement si
#                     install.sh l'y avait ajouté (avec --force : dans tous les cas)
#   --disable-linger  désactive le linger, seulement si install.sh l'avait
#                     activé (avec --force : dans tous les cas)
#   --purge           supprime aussi ~/.config/steamd (configuration)
#
# Ne touche jamais à Steam, à ~/.steam ni aux bibliothèques de jeux.
set -euo pipefail

USER=${USER:-$(id -un)}

BIN_DIR="$HOME/.local/bin"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/steamd"
STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/steamd"
APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
STATE_FILE="$STATE_DIR/install.state"
UDEV_RULE=/etc/udev/rules.d/60-steamd-uinput.rules
MODULES_LOAD=/etc/modules-load.d/steamd-uinput.conf
POLKIT_RULE=/etc/polkit-1/rules.d/60-steamd.rules

REMOVE_GROUP=false
DISABLE_LINGER=false
PURGE=false
FORCE=false

while (($#)); do
	case $1 in
	--remove-group) REMOVE_GROUP=true ;;
	--disable-linger) DISABLE_LINGER=true ;;
	--purge) PURGE=true ;;
	--force) FORCE=true ;;
	-h | --help)
		sed -n '2,13p' "$0"
		exit 0
		;;
	*)
		echo "option inconnue : $1" >&2
		exit 2
		;;
	esac
	shift
done

step() { printf '\n\e[1m==> %s\e[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }

((UID != 0)) || {
	echo "lancer uninstall.sh avec votre utilisateur, pas en root" >&2
	exit 1
}

UINPUT_GROUP=input
ADDED_TO_GROUP=false
ENABLED_LINGER=false
if [[ -r $STATE_FILE ]]; then
	# shellcheck disable=SC1090
	source "$STATE_FILE"
fi

step "Arrêt et désactivation des services"
for u in steamd.service steamd-session-hook.service; do
	if systemctl --user cat "$u" >/dev/null 2>&1; then
		systemctl --user disable "$u" >/dev/null 2>&1 || true
		note "$u désactivé"
	fi
done
systemctl --user stop steamd.service 2>/dev/null || true
# Steam lancé sur le bureau par steamd (unité transitoire) : laissé tel quel.
systemctl --user reset-failed steamd.service steamd-session-hook.service 2>/dev/null || true

step "Fichiers utilisateur"
for f in "$UNIT_DIR/steamd.service" "$UNIT_DIR/steamd-session-hook.service" \
	"$BIN_DIR/steamd-launch" "$BIN_DIR/steamd-doctor" "$BIN_DIR/steamd-session-hook" "$BIN_DIR/steamd-steamcfg" \
	"$APP_DIR/steamd-handover.desktop"; do
	if [[ -e $f ]]; then
		rm -f "$f"
		note "supprimé : $f"
	fi
done
systemctl --user daemon-reload 2>/dev/null || true
if [[ $PURGE == true && -d $CONF_DIR ]]; then
	rm -rf "$CONF_DIR"
	note "supprimé : $CONF_DIR"
elif [[ -d $CONF_DIR ]]; then
	note "conservé : $CONF_DIR (--purge pour le supprimer)"
fi

need_sudo=false
[[ -e $UDEV_RULE || -e $MODULES_LOAD || -e $POLKIT_RULE ]] && need_sudo=true
[[ $REMOVE_GROUP == true || $DISABLE_LINGER == true ]] && need_sudo=true

if [[ $need_sudo == true ]]; then
	step "Partie système (sudo)"
	sudo -v
	if [[ -e $UDEV_RULE ]]; then
		sudo rm -f "$UDEV_RULE"
		sudo udevadm control --reload
		sudo udevadm trigger --name-match=uinput 2>/dev/null || true
		note "supprimé : $UDEV_RULE"
	fi
	if [[ -e $POLKIT_RULE ]]; then
		sudo rm -f "$POLKIT_RULE"
		note "supprimé : $POLKIT_RULE"
	fi
	if [[ -e $MODULES_LOAD ]]; then
		sudo rm -f "$MODULES_LOAD"
		note "supprimé : $MODULES_LOAD (le module reste chargé jusqu'au redémarrage)"
	fi

	if [[ $REMOVE_GROUP == true ]]; then
		if ! id -nG "$USER" | tr ' ' '\n' | grep -qx "$UINPUT_GROUP"; then
			note "$USER n'est pas dans le groupe $UINPUT_GROUP"
		elif [[ $ADDED_TO_GROUP == true || $FORCE == true ]]; then
			sudo gpasswd -d "$USER" "$UINPUT_GROUP" >/dev/null
			ADDED_TO_GROUP=false
			note "$USER retiré du groupe $UINPUT_GROUP"
		else
			note "$USER était déjà dans $UINPUT_GROUP avant install.sh : conservé (--force pour le retirer)"
		fi
	fi

	if [[ $DISABLE_LINGER == true ]]; then
		if [[ $(loginctl show-user "$USER" -p Linger --value 2>/dev/null) != yes ]]; then
			note "linger déjà désactivé"
		elif [[ $ENABLED_LINGER == true || $FORCE == true ]]; then
			sudo loginctl disable-linger "$USER"
			ENABLED_LINGER=false
			note "linger désactivé"
		else
			note "linger était activé avant install.sh : conservé (--force pour le désactiver)"
		fi
	fi
fi

# L'état ne sert plus que s'il reste un groupe ou un linger posés par install.sh.
if [[ $ADDED_TO_GROUP == true || $ENABLED_LINGER == true ]]; then
	cat >"$STATE_FILE" <<EOF
# Généré par steamd/install.sh, lu par uninstall.sh et steamd-doctor.
UINPUT_GROUP=$UINPUT_GROUP
ADDED_TO_GROUP=$ADDED_TO_GROUP
ENABLED_LINGER=$ENABLED_LINGER
EOF
	step "Laissé en place"
	[[ $ADDED_TO_GROUP == true ]] && note "groupe $UINPUT_GROUP (--remove-group pour le retirer)"
	[[ $ENABLED_LINGER == true ]] && note "linger (--disable-linger pour le désactiver)"
else
	rm -f "$STATE_FILE"
	rmdir "$STATE_DIR" 2>/dev/null || true
fi

step "Terminé"
note "Steam et ~/.steam n'ont pas été modifiés."
