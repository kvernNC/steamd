#!/usr/bin/env bash
# tests/run.sh : tests du superviseur steamd et de steamd-steamcfg, avec de
# faux gamescope, Steam, logind, systemctl, notify-send et powerprofilesctl
# (tests/fake). Ne touche ni au vrai Steam ni au système : tout se passe dans
# un dossier temporaire. Durée : environ une minute.
#
#   tests/run.sh            tous les tests
#   tests/run.sh NOM...     seulement ces tests (voir la liste en bas)
# shellcheck disable=SC2016,SC2329,SC2034 # conditions passées à eval, fonctions appelées par nom
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
FAKE=$(mktemp -d)
export FAKE
trap 'pkill -f "$FAKE" 2>/dev/null; pkill -f "fake/steam -tenfoot" 2>/dev/null; rm -rf "$FAKE"' EXIT

export PATH="$ROOT/tests/fake:$PATH"
export HOME=$FAKE/home XDG_RUNTIME_DIR=$FAKE/run XDG_STATE_HOME=$FAKE/state
export STEAMD_CONF=$FAKE/steamd.conf
mkdir -p "$HOME/.steam/steam/steamapps" "$HOME/.steam/steam/config" "$HOME/.steam/steam/userdata/123/config" "$XDG_RUNTIME_DIR"
printf '"AppState"\n{\n\t"appid"\t\t"620"\n\t"name"\t\t"Portal 2"\n}\n' >"$HOME/.steam/steam/steamapps/appmanifest_620.acf"

LAUNCH=$ROOT/bin/steamd-launch
HOOK=$ROOT/bin/steamd-session-hook
CFG=$ROOT/bin/steamd-steamcfg
STATE=$XDG_RUNTIME_DIR/steamd/state

PASS=0
FAIL=0
ok() {
	PASS=$((PASS + 1))
	printf '  \e[32mOK\e[0m  %s\n' "$1"
}
ko() {
	FAIL=$((FAIL + 1))
	printf '  \e[31mKO\e[0m  %s\n' "$1"
}
check() { if eval "$2"; then ok "$1"; else ko "$1 [$2]"; fi; }
state() { head -1 "$STATE" 2>/dev/null; }
why() { sed -n 2p "$STATE" 2>/dev/null; }

# Attend qu'une condition devienne vraie (max $2 secondes).
wait_for() {
	local i
	for ((i = 0; i < ${2:-10} * 5; i++)); do
		eval "$1" && return 0
		sleep 0.2
	done
	return 1
}

reset() {
	stop_sup
	pkill -f "fake/steam -tenfoot" 2>/dev/null
	rm -f "$FAKE"/{session,game,click,events,ppd,sup.pid,peers} "$STATE" "$XDG_RUNTIME_DIR/steamd/profile-request"
	printf 'POLL_INTERVAL=1\nSTOP_TIMEOUT=3\nRESTART_DELAY=1\nHANDOVER_DELAY=2\n%s\n' "${1:-}" >"$STEAMD_CONF"
}
start_sup() {
	"$LAUNCH" >>"$FAKE/log" 2>&1 &
	echo $! >"$FAKE/sup.pid"
	wait_for '[[ $(state) == running || $(state) == standby ]]' 10
}
stop_sup() {
	[[ -s $FAKE/sup.pid ]] || return 0
	local p
	p=$(cat "$FAKE/sup.pid")
	kill -TERM "$p" 2>/dev/null
	wait_for '! kill -0 '"$p"' 2>/dev/null' 15
	rm -f "$FAKE/sup.pid"
}
headless_alive() { pgrep -f "fake/steam -tenfoot" >/dev/null; }
game_alive() { pgrep -f "AppId=620" >/dev/null; }
events() {
	local n
	n=$(grep -c "^$1" "$FAKE/events" 2>/dev/null)
	echo "${n:-0}"
}

# --- Tests ---------------------------------------------------------------------

t_print() {
	echo "print : commande générée"
	reset 'REFRESH=90'
	local cmd
	cmd=$("$LAUNCH" --print 2>/dev/null)
	check "résolution et fréquence" '[[ $cmd == *"-W 1280 -H 800"*"-r 90"*"--backend headless"* ]]'
	check "optimisations stream" '[[ $cmd == *DXVK_CONFIG=*PROTON_DXVK_LOWLATENCY=1*ENABLE_LAYER_MESA_ANTI_LAG=1* ]]'
	check "limite = REFRESH (auto)" '[[ $cmd == *FRAME_RATE=90* || $cmd == *fps_limit=90* ]]'
	reset 'STEAM_CAPTURE=foo'
	"$LAUNCH" --print >/dev/null 2>&1
	check "conf invalide : code 2" '[[ $? == 2 ]]'
}

t_start_stop() {
	echo "start_stop : lancement, plantage, arrêt sans reste"
	reset
	start_sup
	check "running sans session" '[[ $(state) == running ]] && headless_alive'
	pkill -KILL -f "fake/steam -tenfoot"
	wait_for '[[ $(state) == backoff ]]' 5
	check "relance après plantage" 'wait_for "[[ \$(state) == running ]] && headless_alive" 10'
	stop_sup
	check "arrêt : état stopped" '[[ $(state) == stopped ]]'
	check "arrêt : aucun processus restant" '! headless_alive'
}

t_login() {
	echo "login : session de bureau sans partie"
	reset
	start_sup
	touch "$FAKE/session"
	"$HOOK" login 2>/dev/null
	check "hook login rend la main en standby" '[[ $(state) == standby ]]'
	check "Steam headless arrêté" '! headless_alive'
	rm "$FAKE/session"
	"$HOOK" logout 2>/dev/null
	check "reprise après déconnexion" 'wait_for "[[ \$(state) == running ]]" 5'
	check "pas de Steam du bureau lancé" '[[ $(events STEAM_BUREAU) == 0 ]]'
}

t_foreign() {
	echo "foreign : un Steam lancé hors de steamd n'est jamais tué"
	reset
	mkdir -p "$FAKE/desk"
	cp /bin/sleep "$FAKE/desk/steam"
	"$FAKE/desk/steam" 1000 &
	local desk=$!
	start_sup
	check "standby tant que l'autre Steam tourne" '[[ $(state) == standby ]]'
	sleep 2
	check "l'autre Steam est toujours vivant" 'kill -0 $desk 2>/dev/null'
	kill "$desk"
	wait "$desk" 2>/dev/null
	check "reprise une fois l'autre Steam fermé" 'wait_for "[[ \$(state) == running ]]" 5'
}

t_busy() {
	echo "busy : connexion au bureau pendant une partie Remote Play"
	reset
	start_sup
	touch "$FAKE/game"
	wait_for 'game_alive' 5
	touch "$FAKE/session"
	"$HOOK" login 2>/dev/null
	check "partie conservée (busy)" 'wait_for "[[ \$(state) == busy ]]" 5 && game_alive'
	check "popup affichée" '[[ $(events NOTIFICATION) -ge 1 ]]'
	check "veille bloquée pendant la partie" '[[ $(events INHIBIT) -ge 1 ]]'
	check "profil performance pendant la partie" '[[ $(cat "$FAKE/ppd" 2>/dev/null) == performance ]]'
	rm "$FAKE/game"
	check "fin de partie : passage au bureau" 'wait_for "[[ \$(state) == standby ]]" 10'
	check "Steam du bureau lancé" 'wait_for "[[ \$(events STEAM_BUREAU) -ge 1 ]]" 3'
	check "profil d'énergie rétabli" '[[ $(cat "$FAKE/ppd") == balanced ]]'
}

t_handover() {
	echo "handover : bouton de la popup et --handover"
	reset
	start_sup
	touch "$FAKE/game"
	wait_for 'game_alive' 5
	touch "$FAKE/session"
	"$HOOK" login 2>/dev/null
	wait_for '[[ $(state) == busy ]]' 5
	touch "$FAKE/click"
	check "clic : standby" 'wait_for "[[ \$(state) == standby ]]" 10'
	check "clic : partie fermée" '! game_alive'
	check "clic : Steam du bureau lancé" 'wait_for "[[ \$(events STEAM_BUREAU) -ge 1 ]]" 3'
	rm -f "$FAKE/session" "$FAKE/events"
	"$HOOK" logout 2>/dev/null
	wait_for '[[ $(state) == running ]]' 5
	wait_for 'game_alive' 5
	touch "$FAKE/session"
	"$HOOK" login 2>/dev/null
	wait_for '[[ $(state) == busy ]]' 5
	"$LAUNCH" --handover >/dev/null
	check "--handover : standby" 'wait_for "[[ \$(state) == standby ]]" 10'
	check "popup fermée" '! pgrep -f "tests/fake/notify-send" >/dev/null'
}

t_idle() {
	echo "idle : mise en veille après inactivité (IDLE_TIMEOUT=60, ~65 s)"
	reset 'IDLE_ACTION=suspend
IDLE_TIMEOUT=60'
	start_sup
	check "veille demandée après 60 s sans session ni partie" 'wait_for "[[ \$(events SYSTEMCTL_suspend) -ge 1 ]]" 75'
}

t_steamcfg() {
	echo "steamcfg : lecture, découverte et écriture des réglages Steam"
	reset
	local c=$HOME/.steam/steam/config/config.vdf
	printf '"InstallConfigStore"\n{\n\t"Software"\n\t{\n\t\t"Valve"\n\t\t{\n\t\t\t"Steam"\n\t\t\t{\n\t\t\t\t"A"\t\t"0"\n\t\t\t}\n\t\t}\n\t}\n}\n' >"$c"
	printf '"UserLocalConfigStore"\n{\n}\n' >"$HOME/.steam/steam/userdata/123/config/localconfig.vdf"
	check "relecture à l'identique" 'python3 "$CFG" check >/dev/null'
	python3 "$CFG" snapshot >/dev/null
	python3 "$CFG" set config/config.vdf InstallConfigStore/Software/Valve/Steam/A 1 >/dev/null
	check "diff : ligne STEAM_SETTINGS proposée" 'python3 "$CFG" diff | grep -q "STEAM_SETTINGS+=(\"config/config.vdf:InstallConfigStore/Software/Valve/Steam/A=1\")"'
	python3 "$CFG" apply 'userdata/*/config/localconfig.vdf:UserLocalConfigStore/X/Y=2' >/dev/null
	check "apply : clé créée, casse ignorée" '[[ $(python3 "$CFG" get "userdata/*/config/localconfig.vdf" userlocalconfigstore/x/y) == *": 2" ]]'
	check "sauvegarde .steamd.bak" '[[ -e $c.steamd.bak ]]'
	"$ROOT/tests/fake/steam" -tenfoot &
	sleep 0.5
	python3 "$CFG" set config/config.vdf A/B 1 >/dev/null 2>&1
	check "refus si Steam tourne (code 3)" '[[ $? == 3 ]]'
	pkill -f "fake/steam -tenfoot"
	check "chemin hors de Steam refusé" '! python3 "$CFG" get ../../etc/passwd x >/dev/null 2>&1'
}

t_profiles() {
	echo "profiles : profil par défaut + exception par IP"
	reset 'REFRESH=90
PROFILE_REVERT_AFTER=4
CLIENT_PROFILES=("192.168.88.50 OUTPUT=3840x2160 RENDER=2560x1440 REFRESH=60")'
	start_sup
	check "démarrage sur le profil par défaut" '[[ $(why) == *"profil default"* ]] && pgrep -f "fake/gamescope -W 1280 -H 800 .* -r 90" >/dev/null'
	echo 192.168.88.50 >"$FAKE/peers"
	check "connexion de la TV : profil TV" 'wait_for "[[ \$(why) == *\"profil 192.168.88.50\"* ]]" 10'
	check "gamescope relancé en 3840x2160, rendu 2560x1440, 60 Hz" 'pgrep -f "fake/gamescope -W 3840 -H 2160 -w 2560 -h 1440 -r 60" >/dev/null'
	touch "$FAKE/game"
	wait_for 'game_alive' 5
	: >"$FAKE/peers"
	sleep 6
	check "pas de retour au défaut pendant une partie" '[[ $(why) == *"profil 192.168.88.50"* ]] && game_alive'
	rm -f "$FAKE/game"
	check "retour au défaut après PROFILE_REVERT_AFTER sans la TV" 'wait_for "[[ \$(why) == *\"profil default\"* ]]" 15'
	touch "$FAKE/game"
	wait_for 'game_alive' 5
	echo 192.168.88.50 >"$FAKE/peers"
	sleep 3
	check "pas de changement si la TV arrive pendant une partie" '[[ $(why) == *"profil default"* ]] && game_alive'
	rm -f "$FAKE/game" "$FAKE/peers"
	"$LAUNCH" --profile 192.168.88.50 >/dev/null
	check "--profile : changement manuel" 'wait_for "[[ \$(why) == *\"profil 192.168.88.50\"* ]]" 10'
	"$LAUNCH" --profile inconnu >/dev/null 2>&1
	check "--profile inconnu refusé (code 2)" '[[ $? == 2 ]]'
}

ALL=(print start_stop login foreign busy handover profiles steamcfg idle)
for t in "${@:-${ALL[@]}}"; do
	"t_$t"
	echo
done
stop_sup
printf '%d OK, %d KO\n' "$PASS" "$FAIL"
((FAIL == 0)) || {
	echo "journal du superviseur : $FAKE/log (supprimé à la fin, relancer un test seul pour l'examiner)"
	tail -30 "$FAKE/log"
}
exit $((FAIL > 0))
