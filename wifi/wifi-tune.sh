#!/usr/bin/env bash
# wifi-tune.sh : réduit les pics de latence du Wi-Fi pour le streaming.
# Fonctionne sur le Steam Deck (SteamOS) comme sur le PC hôte (CachyOS) :
# tout passe par NetworkManager, sans Decky.
#
#   wifi-tune.sh install     installe et applique les réglages (sudo)
#   wifi-tune.sh uninstall   retire tout et restaure les valeurs d'origine (sudo)
#   wifi-tune.sh status      état du Wi-Fi et des réglages (sans sudo)
#   wifi-tune.sh lock-ap     optionnel : verrouille le réseau Wi-Fi actuel sur
#                            son point d'accès actuel, sans recherche d'autres
#                            points d'accès (sudo)
#   wifi-tune.sh unlock-ap   retire ces verrouillages (sudo)
#
# Réglages appliqués, et réappliqués à chaque connexion Wi-Fi (y compris
# après une mise en veille) par un script « dispatcher » de NetworkManager :
#   - économie d'énergie du Wi-Fi désactivée (la carte ne s'endort plus
#     entre deux paquets) : NetworkManager et iw ;
#   - états d'économie d'énergie PCIe (ASPM) de la carte Wi-Fi désactivés ;
#   - tampons réseau agrandis (rafales du stream) et file d'émission allongée.
# Et, au prochain démarrage, options d'économie d'énergie du pilote
# désactivées (rtw88 du Deck LCD, rtw89, mt7921e, iwlwifi ; rien à faire pour
# ath11k du Deck OLED).
#
# Inspiré des réglages du plugin Decky WifiOptimizer
# (https://github.com/ArcadaLabs-Jason/WifiOptimizer), réécrit sans Decky.
#
# Sur SteamOS, /etc est conservé lors des mises à jour : les réglages
# survivent. sudo demande que le mot de passe de l'utilisateur deck soit
# défini (passwd).
set -euo pipefail

# WIFI_TUNE_ROOT : préfixe pour les tests seulement.
R=${WIFI_TUNE_ROOT:-}
NM_CONF=$R/etc/NetworkManager/conf.d/99-steamd-wifi.conf
DISPATCHER=$R/etc/NetworkManager/dispatcher.d/99-steamd-wifi
MODPROBE=$R/etc/modprobe.d/99-steamd-wifi.conf
STATE_DIR=$R/var/lib/steamd-wifi

SYSCTLS=(
	net.core.rmem_max=16777216
	net.core.wmem_max=16777216
	net.core.rmem_default=1048576
	net.core.wmem_default=1048576
	net.core.netdev_max_backlog=5000
	net.core.netdev_budget=600
	net.core.netdev_budget_usecs=8000
)

note() { printf '    %s\n' "$*"; }
step() { printf '\n\e[1m==> %s\e[0m\n' "$*"; }
die() {
	printf '\e[31merreur :\e[0m %s\n' "$*" >&2
	exit 1
}

as_root() {
	if ((EUID != 0)) && [[ -z $R ]]; then
		exec sudo -- "$(readlink -f -- "$0")" "$@"
	fi
}

wifi_ifaces() {
	local d
	for d in /sys/class/net/*/wireless; do
		[[ -e $d ]] && basename "$(dirname "$d")"
	done
}

module_of() {
	local m
	m=$(readlink -f "/sys/class/net/$1/device/driver/module" 2>/dev/null) || return 0
	basename "$m"
}

# Options du pilote, selon le module de la carte.
modprobe_options() {
	case $1 in
	rtw88_*) printf '%s\n' "options rtw88_core disable_lps_deep=Y" "options rtw88_pci disable_aspm=Y" ;;
	rtw89_*) printf '%s\n' "options rtw89_pci disable_aspm_l1=Y" "options rtw89_pci disable_aspm_l1ss=Y" ;;
	mt7921e) printf '%s\n' "options mt7921e disable_aspm=Y" ;;
	iwlwifi) printf '%s\n' "options iwlwifi power_save=0 uapsd_disable=3" "options iwlmvm power_scheme=1" ;;
	*) ;; # ath11k_pci, ath12k... : rien
	esac
}

# Script exécuté par NetworkManager à chaque connexion d'une interface.
write_dispatcher() {
	cat >"$DISPATCHER" <<EOF
#!/bin/bash
# Généré par steamd/wifi/wifi-tune.sh : réglages Wi-Fi pour le streaming,
# réappliqués à chaque connexion Wi-Fi. Retrait : wifi-tune.sh uninstall
IFACE=\$1
ACTION=\$2
[[ \$ACTION == up || \$ACTION == reapply ]] || exit 0
[[ -d /sys/class/net/\$IFACE/wireless ]] || exit 0

# Économie d'énergie du Wi-Fi désactivée.
iw dev "\$IFACE" set power_save off 2>/dev/null || true

# États d'économie d'énergie PCIe de la carte désactivés.
pci=\$(readlink -f "/sys/class/net/\$IFACE/device")
if [[ -d \$pci/link ]]; then
	for f in l0s_aspm l1_aspm l1_1_aspm l1_2_aspm l1_1_pcipm l1_2_pcipm; do
		[[ -w \$pci/link/\$f ]] && echo 0 >"\$pci/link/\$f" 2>/dev/null
	done
fi
[[ -w \$pci/power/control ]] && echo on >"\$pci/power/control" 2>/dev/null

# Tampons réseau : valeurs d'origine sauvegardées une fois, pour uninstall.
mkdir -p $STATE_DIR
if [[ ! -s $STATE_DIR/sysctl.baseline ]]; then
	for kv in ${SYSCTLS[*]}; do
		k=\${kv%%=*}
		echo "\$k=\$(sysctl -n "\$k")"
	done >$STATE_DIR/sysctl.baseline
fi
for kv in ${SYSCTLS[*]}; do
	sysctl -qw "\$kv" 2>/dev/null || true
done
ip link set "\$IFACE" txqueuelen 2000 2>/dev/null || true

logger -t steamd-wifi "réglages streaming appliqués sur \$IFACE" 2>/dev/null || true
exit 0
EOF
	chmod 0755 "$DISPATCHER"
}

cmd_install() {
	as_root install
	command -v nmcli >/dev/null || die "NetworkManager (nmcli) est requis"
	command -v iw >/dev/null || die "iw est requis"
	mapfile -t ifaces < <(wifi_ifaces)
	((${#ifaces[@]})) || die "aucune interface Wi-Fi trouvée"

	step "NetworkManager : économie d'énergie du Wi-Fi désactivée"
	printf '# Généré par steamd/wifi/wifi-tune.sh\n[connection]\nwifi.powersave = 2\n' >"$NM_CONF"
	note "$NM_CONF"

	step "Script de connexion NetworkManager"
	mkdir -p "$STATE_DIR"
	write_dispatcher
	note "$DISPATCHER"

	step "Options du pilote (prises en compte au prochain démarrage)"
	local opts="" i m
	for i in "${ifaces[@]}"; do
		m=$(module_of "$i")
		note "$i : pilote ${m:-inconnu}"
		opts+=$(modprobe_options "$m")$'\n'
	done
	opts=$(printf '%s' "$opts" | sed '/^$/d' | sort -u)
	if [[ -n $opts ]]; then
		printf '# Généré par steamd/wifi/wifi-tune.sh\n%s\n' "$opts" >"$MODPROBE"
		note "$MODPROBE :"
		while IFS= read -r line; do note "  $line"; done <<<"$opts"
	else
		rm -f "$MODPROBE"
		note "aucune option nécessaire pour ce pilote"
	fi

	step "Application immédiate"
	nmcli general reload conf 2>/dev/null || true
	for i in "${ifaces[@]}"; do
		"$DISPATCHER" "$i" up
		note "$i : power_save $(iw dev "$i" get power_save 2>/dev/null | awk '{print $NF}')"
	done
	[[ -n $opts ]] && note "Redémarrer pour appliquer les options du pilote."
	note "État : wifi-tune.sh status"
}

cmd_uninstall() {
	as_root uninstall
	step "Retrait des réglages Wi-Fi"
	local f
	for f in "$NM_CONF" "$DISPATCHER" "$MODPROBE"; do
		if [[ -e $f ]]; then
			rm -f "$f"
			note "supprimé : $f"
		fi
	done
	if [[ -s $STATE_DIR/sysctl.baseline ]]; then
		while IFS= read -r kv; do
			sysctl -qw "$kv" 2>/dev/null || true
		done <"$STATE_DIR/sysctl.baseline"
		note "tampons réseau restaurés"
	fi
	if [[ -s $STATE_DIR/locked ]]; then
		cmd_unlock_ap
	fi
	rm -rf "$STATE_DIR"
	nmcli general reload conf 2>/dev/null || true
	local i
	for i in $(wifi_ifaces); do
		ip link set "$i" txqueuelen 1000 2>/dev/null || true
	done
	note "Redémarrer pour revenir complètement aux réglages d'origine (économie d'énergie, PCIe, pilote)."
}

cmd_lock_ap() {
	as_root lock-ap
	local i bssid uuid name
	mkdir -p "$STATE_DIR"
	for i in $(wifi_ifaces); do
		bssid=$(iw dev "$i" link 2>/dev/null | awk '/^Connected to/{print $3}')
		[[ -n $bssid ]] || continue
		uuid=$(nmcli -t -f UUID,DEVICE connection show --active 2>/dev/null | awk -F: -v d="$i" '$2 == d {print $1; exit}')
		[[ -n $uuid ]] || continue
		name=$(nmcli -g connection.id connection show uuid "$uuid" 2>/dev/null)
		nmcli connection modify uuid "$uuid" 802-11-wireless.bssid "$bssid"
		grep -qx "$uuid" "$STATE_DIR/locked" 2>/dev/null || echo "$uuid" >>"$STATE_DIR/locked"
		note "« $name » verrouillé sur le point d'accès $bssid"
		note "Ce réseau ne cherchera plus d'autre point d'accès. Si ce point d'accès disparaît"
		note "(autre pièce, autre bâtiment), le Deck ne s'y reconnectera plus : wifi-tune.sh unlock-ap"
	done
}

cmd_unlock_ap() {
	as_root unlock-ap
	[[ -s $STATE_DIR/locked ]] || {
		note "aucun réseau verrouillé"
		return 0
	}
	local uuid
	while IFS= read -r uuid; do
		nmcli connection modify uuid "$uuid" 802-11-wireless.bssid "" 2>/dev/null &&
			note "déverrouillé : $(nmcli -g connection.id connection show uuid "$uuid" 2>/dev/null)"
	done <"$STATE_DIR/locked"
	rm -f "$STATE_DIR/locked"
}

cmd_status() {
	local i m pci f
	printf '\e[1mRéglages installés\e[0m\n'
	for f in "$NM_CONF" "$DISPATCHER" "$MODPROBE"; do
		if [[ -e $f ]]; then note "oui : $f"; else note "non : $f"; fi
	done
	for i in $(wifi_ifaces); do
		m=$(module_of "$i")
		printf '\n\e[1m%s\e[0m (pilote %s)\n' "$i" "${m:-inconnu}"
		note "économie d'énergie : $(iw dev "$i" get power_save 2>/dev/null | awk '{print $NF}')"
		pci=$(readlink -f "/sys/class/net/$i/device")
		if [[ -d $pci/link ]]; then
			local states=""
			for f in l1_aspm l1_1_aspm l1_2_aspm; do
				[[ -r $pci/link/$f ]] && states+=" $f=$(cat "$pci/link/$f")"
			done
			note "PCIe ASPM :${states:- non exposé}"
		fi
		note "file d'émission : $(cat "/sys/class/net/$i/tx_queue_len" 2>/dev/null)"
		iw dev "$i" link 2>/dev/null | sed -n 's/^\t\(SSID\|freq\|signal\|tx bitrate\|rx bitrate\): */\1 : /p' | sed 's/^/    /'
	done
	printf '\n\e[1mTampons réseau\e[0m\n'
	note "$(sysctl -n net.core.rmem_max 2>/dev/null) octets max en réception, $(sysctl -n net.core.rmem_default 2>/dev/null) par défaut"
	if [[ -s $STATE_DIR/locked ]]; then
		printf '\n\e[1m%s\e[0m\n' "Réseaux verrouillés sur leur point d'accès"
		while IFS= read -r u; do note "$(nmcli -g connection.id,802-11-wireless.bssid connection show uuid "$u" 2>/dev/null | paste -sd' ')"; done <"$STATE_DIR/locked"
	fi
}

case ${1:-} in
install) cmd_install ;;
uninstall) cmd_uninstall ;;
status) cmd_status ;;
lock-ap) cmd_lock_ap ;;
unlock-ap) cmd_unlock_ap ;;
*)
	sed -n '2,13p' "$0"
	exit 2
	;;
esac
