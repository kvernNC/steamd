#!/usr/bin/env bash
# install.sh : installe steamd pour l'utilisateur courant. Idempotent.
#
#   ./install.sh [--group NOM] [--no-enable] [--start]
#
#   --group NOM   groupe qui reçoit l'accès à /dev/uinput (défaut : input)
#   --no-enable   installe sans activer steamd au démarrage
#   --start       démarre steamd à la fin (sinon : au prochain boot)
#
# À lancer avec l'utilisateur qui joue, pas en root : sudo est demandé
# seulement pour la règle udev, le module uinput, le groupe et le linger.
set -euo pipefail

USER=${USER:-$(id -un)}

REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BIN_DIR="$HOME/.local/bin"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/steamd"
STATE_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/steamd"
STATE_FILE="$STATE_DIR/install.state"
UDEV_RULE=/etc/udev/rules.d/60-steamd-uinput.rules
MODULES_LOAD=/etc/modules-load.d/steamd-uinput.conf

UINPUT_GROUP=input
ENABLE=true
START=false

usage() { sed -n '2,12p' "$0"; }

while (($#)); do
	case $1 in
	--group)
		UINPUT_GROUP=${2:?--group attend un nom}
		shift
		;;
	--group=*) UINPUT_GROUP=${1#*=} ;;
	--no-enable) ENABLE=false ;;
	--start) START=true ;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "option inconnue : $1" >&2
		usage >&2
		exit 2
		;;
	esac
	shift
done

step() { printf '\n\e[1m==> %s\e[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '    \e[33mattention :\e[0m %s\n' "$*"; }
die() {
	printf '\e[31merreur :\e[0m %s\n' "$*" >&2
	exit 1
}

((UID != 0)) || die "lancer install.sh avec votre utilisateur, pas en root (sudo sera demandé au besoin)"
[[ $UINPUT_GROUP =~ ^[a-z_][a-z0-9_-]*$ ]] || die "nom de groupe invalide : $UINPUT_GROUP"
command -v systemctl >/dev/null || die "systemd est requis"
systemctl --user show-environment >/dev/null 2>&1 ||
	die "gestionnaire systemd utilisateur injoignable (en SSH, XDG_RUNTIME_DIR=/run/user/$UID est-il défini ?)"

for b in gamescope steam; do
	command -v "$b" >/dev/null || warn "$b introuvable : sudo pacman -S $b"
done

# --- État : ce que install.sh a lui-même changé (pour uninstall.sh) -----------
ADDED_TO_GROUP=false
ENABLED_LINGER=false
mkdir -p "$STATE_DIR"
if [[ -r $STATE_FILE ]]; then
	# shellcheck disable=SC1090
	source "$STATE_FILE"
fi
save_state() {
	cat >"$STATE_FILE" <<EOF
# Généré par steamd/install.sh, lu par uninstall.sh et steamd-doctor.
UINPUT_GROUP=$UINPUT_GROUP
ADDED_TO_GROUP=$ADDED_TO_GROUP
ENABLED_LINGER=$ENABLED_LINGER
EOF
}

# --- Fichiers utilisateur ----------------------------------------------------
step "Scripts dans $BIN_DIR"
mkdir -p "$BIN_DIR"
for f in steamd-launch steamd-doctor steamd-session-hook; do
	install -m 0755 "$REPO_DIR/bin/$f" "$BIN_DIR/$f"
	note "$BIN_DIR/$f"
done
case ":$PATH:" in
*":$BIN_DIR:"*) ;;
*) warn "$BIN_DIR n'est pas dans le PATH (les unités systemd utilisent le chemin complet, steamd-doctor non)" ;;
esac

step "Unités systemd utilisateur dans $UNIT_DIR"
mkdir -p "$UNIT_DIR"
for u in steamd.service steamd-session-hook.service; do
	install -m 0644 "$REPO_DIR/systemd/$u" "$UNIT_DIR/$u"
	note "$UNIT_DIR/$u"
done

step "Configuration"
mkdir -p "$CONF_DIR"
if [[ -e $CONF_DIR/steamd.conf ]]; then
	note "$CONF_DIR/steamd.conf existe déjà, conservé"
else
	install -m 0644 "$REPO_DIR/config/steamd.conf.example" "$CONF_DIR/steamd.conf"
	note "créé : $CONF_DIR/steamd.conf"
fi

# --- Partie système (sudo) ---------------------------------------------------
step "Droits administrateur (udev, uinput, groupe, linger)"
sudo -v || die "sudo est nécessaire pour cette étape"

getent group "$UINPUT_GROUP" >/dev/null || die "le groupe $UINPUT_GROUP n'existe pas (sudo groupadd -r $UINPUT_GROUP)"

tmp_rule=$(mktemp)
trap 'rm -f "$tmp_rule"' EXIT
sed "s/@GROUP@/$UINPUT_GROUP/g" "$REPO_DIR/udev/60-steamd-uinput.rules" >"$tmp_rule"
if sudo cmp -s "$tmp_rule" "$UDEV_RULE" 2>/dev/null; then
	note "règle udev déjà à jour : $UDEV_RULE"
else
	sudo install -m 0644 "$tmp_rule" "$UDEV_RULE"
	note "règle udev installée : $UDEV_RULE (groupe $UINPUT_GROUP)"
fi

if [[ -f $MODULES_LOAD ]] && grep -qx uinput "$MODULES_LOAD"; then
	note "module uinput déjà chargé au boot ($MODULES_LOAD)"
else
	echo uinput | sudo tee "$MODULES_LOAD" >/dev/null
	note "module uinput chargé au boot : $MODULES_LOAD"
fi
sudo modprobe uinput
sudo udevadm control --reload
sudo udevadm trigger --name-match=uinput 2>/dev/null || sudo udevadm trigger --subsystem-match=misc
note "udev rechargé, /dev/uinput : $(stat -c '%A %U:%G' /dev/uinput 2>/dev/null || echo absent)"

NEED_REBOOT=false
if id -nG "$USER" | tr ' ' '\n' | grep -qx "$UINPUT_GROUP"; then
	note "$USER est déjà membre du groupe $UINPUT_GROUP"
else
	sudo gpasswd -a "$USER" "$UINPUT_GROUP" >/dev/null
	ADDED_TO_GROUP=true
	NEED_REBOOT=true
	note "$USER ajouté au groupe $UINPUT_GROUP (pris en compte au prochain redémarrage)"
fi

if [[ $(loginctl show-user "$USER" -p Linger --value 2>/dev/null) == yes ]]; then
	note "linger déjà activé"
else
	sudo loginctl enable-linger "$USER"
	ENABLED_LINGER=true
	note "linger activé : le gestionnaire systemd de $USER démarre au boot"
fi
save_state

# --- Activation --------------------------------------------------------------
step "Services utilisateur"
systemctl --user daemon-reload
for u in pipewire.socket pipewire-pulse.socket wireplumber.service; do
	if systemctl --user cat "$u" >/dev/null 2>&1; then
		systemctl --user enable "$u" >/dev/null 2>&1 || true
		note "$u : $(systemctl --user is-enabled "$u" 2>/dev/null || true)"
	else
		warn "$u introuvable : sudo pacman -S pipewire pipewire-pulse wireplumber"
	fi
done
if [[ $ENABLE == true ]]; then
	systemctl --user enable steamd.service steamd-session-hook.service >/dev/null
	note "steamd.service et steamd-session-hook.service activés"
else
	note "--no-enable : steamd n'est pas activé au démarrage"
fi

if [[ $START == true ]]; then
	step "Démarrage de steamd"
	if pgrep -u "$UID" -x steam >/dev/null; then
		warn "un Steam tourne déjà : le fermer avant (steam -shutdown), steamd attendra ${STEAM_WAIT_TIMEOUT:-60}s"
	fi
	systemctl --user restart --no-block steamd.service
	note "suivre les logs : journalctl --user -u steamd -f"
elif systemctl --user is-active --quiet steamd.service; then
	systemctl --user try-restart --no-block steamd.service
	note "steamd était actif : relancé avec la nouvelle version"
fi

step "Terminé"
if [[ $NEED_REBOOT == true ]]; then
	note "Redémarrer le PC pour appliquer le groupe $UINPUT_GROUP au service."
fi
note "Prérequis manuels (une seule fois) : voir la section du README."
note "Diagnostic : steamd-doctor"
