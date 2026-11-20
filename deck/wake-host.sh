#!/usr/bin/env bash
# wake-host.sh : réveille le PC hôte depuis le Steam Deck (Wake-on-LAN).
#
# À ajouter comme jeu non-Steam depuis le mode bureau, pour le lancer depuis
# le mode jeu. Le magic packet part en broadcast sur le LAN ; le Raspberry Pi
# le relaie vers la carte Ethernet du PC.
#
#   wake-host.sh [MAC]
#
# Réglages : modifier les variables ci-dessous, ou créer
# ~/.config/steamd/wake-host.conf avec les mêmes variables.
# Journal : ~/.local/state/steamd/wake-host.log (le mode jeu n'affiche rien).

# --- Réglages ----------------------------------------------------------------
HOST_MAC="AA:BB:CC:DD:EE:FF"  # MAC attendue par le relais (celle du PC côté LAN)
BROADCAST="255.255.255.255"   # ou le broadcast du LAN, ex. 192.168.1.255
PORT=9                        # port UDP du magic packet (souvent 9 ou 7)
COUNT=3                       # nombre d'envois (l'UDP peut se perdre)
# Optionnel : attendre que le PC réponde au ping avant de rendre la main.
HOST_ADDR=""                  # IP ou nom du PC, vide = ne pas attendre
WAIT_TIMEOUT=90               # secondes, utilisé seulement si HOST_ADDR est défini
# Hors du réseau local (VPN WireGuard) : le broadcast ne traverse pas le
# tunnel. Une machine du LAN (MikroTik ou Raspberry Pi) envoie alors le magic
# packet, en SSH par clé (pas de mot de passe possible en mode jeu).
WAKE_SSH=""                   # ex. "admin@192.168.88.1" ; vide = jamais en SSH
WAKE_SSH_CMD=""               # commande lancée sur cette machine, {MAC} remplacé :
#   MikroTik : '/tool wol interface=bridge mac={MAC}'
#   Pi       : 'wakeonlan {MAC}'
WAKE_SSH_MODE=auto            # auto (SSH si un tunnel WireGuard est actif), always, never
# -----------------------------------------------------------------------------

set -uo pipefail

CONF="${WAKE_HOST_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/steamd/wake-host.conf}"
# shellcheck disable=SC1090
[[ -r $CONF ]] && source "$CONF"
[[ -n ${1:-} ]] && HOST_MAC=$1

LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/steamd"
mkdir -p "$LOG_DIR" 2>/dev/null
LOG="$LOG_DIR/wake-host.log"
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG" >&2; }

if [[ ! $HOST_MAC =~ ^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$ ]]; then
	log "MAC invalide : '$HOST_MAC' (format attendu AA:BB:CC:DD:EE:FF)"
	exit 2
fi
if [[ $HOST_MAC == "AA:BB:CC:DD:EE:FF" ]]; then
	log "HOST_MAC n'est pas configurée (éditer $0 ou $CONF)"
	exit 2
fi

send_python() {
	python3 - "$HOST_MAC" "$BROADCAST" "$PORT" "$COUNT" <<'PY'
import socket, sys, time
mac, bcast, port, count = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
payload = b"\xff" * 6 + bytes.fromhex(mac.replace(":", "").replace("-", "")) * 16
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    for i in range(count):
        s.sendto(payload, (bcast, port))
        if i + 1 < count:
            time.sleep(0.2)
PY
}

send_wakeonlan() {
	local i
	for ((i = 0; i < COUNT; i++)); do
		wakeonlan -i "$BROADCAST" -p "$PORT" "$HOST_MAC" >/dev/null || return 1
	done
}

# Le Deck passe-t-il par un tunnel WireGuard pour joindre le PC ?
via_vpn() {
	if [[ -n $HOST_ADDR ]]; then
		local dev
		dev=$(ip route get "$HOST_ADDR" 2>/dev/null | grep -o 'dev [^ ]*' | cut -d' ' -f2)
		[[ -n $dev ]] && ip -d link show "$dev" 2>/dev/null | grep -q wireguard && return 0
		[[ $dev == wg* ]] && return 0
		return 1
	fi
	ip -o link show type wireguard up 2>/dev/null | grep -q .
}

send_ssh() {
	[[ -n $WAKE_SSH_CMD ]] || {
		log "WAKE_SSH est défini mais pas WAKE_SSH_CMD (voir les exemples en tête de script)"
		return 2
	}
	local cmd=${WAKE_SSH_CMD//\{MAC\}/$HOST_MAC}
	ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "$WAKE_SSH" "$cmd" >/dev/null
}

use_ssh=false
case $WAKE_SSH_MODE in
always) use_ssh=true ;;
auto) [[ -n $WAKE_SSH ]] && via_vpn && use_ssh=true ;;
never) ;;
*)
	log "WAKE_SSH_MODE invalide : $WAKE_SSH_MODE (auto, always, never)"
	exit 2
	;;
esac

if [[ $use_ssh == true ]]; then
	method="ssh $WAKE_SSH"
	send_ssh
elif command -v wakeonlan >/dev/null 2>&1; then
	method=wakeonlan
	send_wakeonlan
elif command -v python3 >/dev/null 2>&1; then
	method=python3
	send_python
else
	log "ni wakeonlan ni python3 disponible"
	exit 1
fi
rc=$?
if ((rc != 0)); then
	log "échec de l'envoi ($method, code $rc)"
	[[ $use_ssh == true ]] && log "piste : clé SSH du Deck autorisée sur $WAKE_SSH ? test : ssh -o BatchMode=yes $WAKE_SSH true"
	exit 1
fi
if [[ $use_ssh == true ]]; then
	log "magic packet pour $HOST_MAC envoyé depuis $WAKE_SSH (mode $WAKE_SSH_MODE)"
else
	log "magic packet envoyé à $HOST_MAC via $BROADCAST:$PORT (${COUNT}x, $method)"
fi

if [[ -n $HOST_ADDR ]]; then
	log "attente de $HOST_ADDR (max ${WAIT_TIMEOUT}s)"
	start=$SECONDS
	while ((SECONDS - start < WAIT_TIMEOUT)); do
		if ping -c1 -W1 "$HOST_ADDR" >/dev/null 2>&1; then
			log "$HOST_ADDR répond après $((SECONDS - start))s"
			exit 0
		fi
		sleep 1
	done
	log "$HOST_ADDR ne répond pas après ${WAIT_TIMEOUT}s"
	exit 1
fi
