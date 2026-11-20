#!/usr/bin/env bash
# tests/run.sh : tests de steamd avec de faux gamescope, systemctl, ss, pactl,
# systemd-inhibit et powerprofilesctl (tests/fake). Ne touche ni au vrai Steam
# ni au système : tout se passe dans un dossier temporaire.
#
#   tests/run.sh            tous les tests
#   tests/run.sh NOM...     seulement ces tests (liste en bas)
# Le test vaapi compile src/steamd-vaapi.c : il demande cc et les en-têtes libva
# (paquet libva, ou VA_INCLUDE=dossier contenant va/va.h) ; sinon il est sauté.
# shellcheck disable=SC2016 # conditions passées à eval
set -uo pipefail

ROOT=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
FAKE=$(mktemp -d)
export FAKE
trap 'kill $(jobs -p) 2>/dev/null; pkill -f "$FAKE" 2>/dev/null; rm -rf "$FAKE"' EXIT

export PATH="$ROOT/tests/fake:$PATH"
export HOME=$FAKE/home XDG_RUNTIME_DIR=$FAKE/run STEAMD_CGROUP_ROOT=$FAKE/cg
unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME
SD=$FAKE/sd                       # STEAMD_HOME du client steamd
STEAMDIR=$SD/.local/share/Steam
CONF=$HOME/.config/steamd/steamd.conf
LAUNCH=$ROOT/bin/steamd-launch PROFILED=$ROOT/bin/steamd-profiled CFG=$ROOT/bin/steamd-steamcfg

PASS=0 FAIL=0 SKIP=0
ok() { PASS=$((PASS + 1)); printf '  \e[32mOK\e[0m  %s\n' "$1"; }
ko() { FAIL=$((FAIL + 1)); printf '  \e[31mKO\e[0m  %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf '  --  %s (sauté)\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else ko "$1 [$2]"; fi; }
wait_for() {
    local i
    for ((i = 0; i < ${2:-10} * 10; i++)); do
        eval "$1" && return 0
        sleep 0.1
    done
    return 1
}

# Conf de test : STEAMD_HOME dans le dossier temporaire, puis les lignes données
reset() {
    pkill -f "$FAKE" 2>/dev/null
    rm -rf "$FAKE"/{run,cg,events,gamescope.out,sinks,default-sink,pactl.log,pactl-ko,power,peers,steampid,inactive,steam.log}
    mkdir -p "$HOME/.config/steamd" "$XDG_RUNTIME_DIR/steamd" "$FAKE/cg/steamd" "$STEAMDIR/userdata/42/config"
    printf '"UserLocalConfigStore"\n{\n\t"Streaming"\n\t{\n\t\t"EnableHardwareEncoding"\t\t"0"\n\t}\n}\n' \
        >"$STEAMDIR/userdata/42/config/localconfig.vdf"
    { echo "STEAMD_HOME=$SD"; printf '%s\n' "$@"; } >"$CONF"
}
launch() { "$LAUNCH" "$@" >"$FAKE/launch.out" 2>&1; echo $? >"$FAKE/launch.code"; }
code() { cat "$FAKE/launch.code"; }
args() { grep '^ARGS' "$FAKE/gamescope.out" 2>/dev/null; }

# --- Tests ------------------------------------------------------------------

t_launch() {
    echo "== lancement : commande gamescope"
    reset "WIDTH=1280" "HEIGHT=800" "REFRESH=90" "STREAM_TUNING=false" "FPS_LIMIT=0"
    launch
    check "code 0" '[[ $(code) == 0 ]]'
    check "sortie et rendu 1280x800 à 90 Hz" 'args | grep -q -- "-W 1280 -H 800 -w 1280 -h 800 -r 90 --backend headless"'
    check "Steam Big Picture et capture dmabuf" 'args | grep -q -- "steam -tenfoot -pipewire-dmabuf"'
    check "pas d'environnement de jeu" '! args | grep -q " env "'
    check "HOME de Steam = STEAMD_HOME" 'grep -qx "ENV HOME=$SD" "$FAKE/gamescope.out"'

    reset "APP_WIDTH=960" "APP_HEIGHT=600" "STEAM_CAPTURE=pipewire" "STREAM_TUNING=false" "FPS_LIMIT=0"
    launch
    check "APP_WIDTH/APP_HEIGHT : rendu séparé" 'args | grep -q -- "-W 1280 -H 800 -w 960 -h 600"'
    check "STEAM_CAPTURE=pipewire" 'args | grep -q -- "-tenfoot -pipewire$"'
}

t_config() {
    echo "== configuration invalide : code 2"
    local c
    for c in "REFRESH=9999999990" "WIDTH=abc" "APP_HEIGHT=0" "HDR=oui" "STEAM_CAPTURE=x" "ENCODER=gpu" \
        "STREAM_TUNING=peut-être" "FPS_LIMIT=-1" "FPS_LIMIT_METHOD=x" "FPS_LIMIT_TIMING=x" \
        'STEAM_ENV=("pas bon")' 'STEAM_SETTINGS=("sans-deux-points=1")' \
        'CLIENT_PROFILES=("tv OUTPUT=1920x1080")' 'CLIENT_PROFILES=("1.2.3.4 OUTPUT=4k")' \
        'CLIENT_PROFILES=("1.2.3.4 OUTPUT=0x800")' 'CLIENT_PROFILES=("1.2.3.4 COULEUR=bleu")' \
        "AUDIO_ISOLATE=true AUDIO_SINK='a b'"; do
        reset "$c"
        launch
        check "« $c » refusé, gamescope non lancé" '[[ $(code) == 2 && ! -e $FAKE/gamescope.out ]]'
    done
    reset 'STEAM_SETTINGS=("sans-deux-points=1")'
    launch
    check "conf refusée avant toute écriture dans Steam" '! grep -q steamd-steamcfg "$FAKE/launch.out"'
}

t_profiles() {
    echo "== profils par client"
    reset "REFRESH=90" "STREAM_TUNING=false" \
        'CLIENT_PROFILES=( "192.168.88.50,10.0.0.5 OUTPUT=3840x2160 RENDER=2560x1440 REFRESH=60 HDR=true FPS_LIMIT=30" "192.168.88.60 OUTPUT=1920x1080" )'
    "$LAUNCH" --profiles >"$FAKE/p.out" 2>&1
    check "--profiles : défaut" 'grep -q "^default .*sortie 1280x800, rendu 1280x800, 90 Hz, HDR false, limite 90" "$FAKE/p.out"'
    check "--profiles : TV" 'grep -q "^192.168.88.50 .*sortie 3840x2160, rendu 2560x1440, 60 Hz, HDR true, limite 30" "$FAKE/p.out"'
    check "OUTPUT sans RENDER : rendu = sortie" 'grep -q "^192.168.88.60 .*rendu 1920x1080" "$FAKE/p.out"'
    check "--profile-for : seconde IP d'une entrée" '[[ $("$LAUNCH" --profile-for 8.8.8.8 10.0.0.5) == 192.168.88.50 ]]'
    check "--profile-for : IP inconnue" '[[ -z $("$LAUNCH" --profile-for 8.8.8.8) ]]'
    "$LAUNCH" --profile 192.168.88.50 >/dev/null
    check "--profile : demande écrite" '[[ $(cat "$XDG_RUNTIME_DIR/steamd/profile.request") == 192.168.88.50 ]]'
    check "--profile inconnu : code 2" '"$LAUNCH" --profile 1.2.3.4 >/dev/null 2>&1; [[ $? == 2 ]]'

    echo 192.168.88.50 >"$XDG_RUNTIME_DIR/steamd/profile"
    launch
    check "profil TV : sortie 4K, rendu 1440p, 60 Hz" 'args | grep -q -- "-W 3840 -H 2160 -w 2560 -h 1440 -r 60"'
    check "profil TV : HDR (gamescope et DXVK)" 'args | grep -q -- "--hdr-enabled" && args | grep -q "DXVK_HDR=1"'
    check "profil TV : limite 30 i/s" 'args | grep -qE "(fps_limit=30|DXVK_FRAME_RATE=30)"'

    echo 9.9.9.9 >"$XDG_RUNTIME_DIR/steamd/profile"
    launch
    check "profil actif disparu : défaut, fichier retiré" 'args | grep -q -- "-W 1280 -H 800" && [[ ! -e $XDG_RUNTIME_DIR/steamd/profile ]]'
}

t_tuning() {
    echo "== jeux : STREAM_TUNING, FPS_LIMIT, STEAM_ENV"
    reset "REFRESH=90" 'STEAM_ENV=( "PROTON_DXVK_LOWLATENCY=0" "DXVK_HUD=fps" )'
    launch
    check "maxFrameLatency=1" 'args | grep -q "DXVK_CONFIG=dxgi.maxFrameLatency=1;d3d9.maxFrameLatency=1"'
    check "low latency Proton-CachyOS et Anti-Lag" 'args | grep -q "PROTON_DXVK_LOWLATENCY=1 PROTON_VKD3D_LOWLATENCY=1 ENABLE_LAYER_MESA_ANTI_LAG=1"'
    check "FPS_LIMIT=auto : limite à REFRESH" 'args | grep -qE "(fps_limit=90|DXVK_FRAME_RATE=90)"'
    check "STEAM_ENV en dernier (l'emporte)" 'args | grep -qE "PROTON_DXVK_LOWLATENCY=1 .*PROTON_DXVK_LOWLATENCY=0 DXVK_HUD=fps steam"'
    if compgen -G '/usr/share/vulkan/implicit_layer.d/MangoHud*.json' >/dev/null; then
        check "MangoHud présent : limite par MangoHud" 'args | grep -q "MANGOHUD=1"'
    else
        check "MangoHud absent : repli DXVK/VKD3D" 'args | grep -q "DXVK_FRAME_RATE=90 VKD3D_FRAME_RATE=90" && grep -q "MangoHud absent" "$FAKE/launch.out"'
    fi
    reset "FPS_LIMIT_METHOD=dxvk" "FPS_LIMIT=45" "STREAM_TUNING=false"
    launch
    check "FPS_LIMIT=45 par DXVK" 'args | grep -q "env DXVK_FRAME_RATE=45 VKD3D_FRAME_RATE=45 steam"'
}

t_encoder() {
    echo "== ENCODER et STEAM_SETTINGS"
    local vdf=$STEAMDIR/userdata/42/config/localconfig.vdf
    reset "ENCODER=hardware" 'STEAM_SETTINGS=( "userdata/*/config/localconfig.vdf:UserLocalConfigStore/Streaming/MonOption=7" )'
    launch
    check "ENCODER=hardware : EnableHardwareEncoding à 1" 'grep -q "\"EnableHardwareEncoding\"[[:space:]]*\"1\"" "$vdf"'
    check "STEAM_SETTINGS appliqué avant le lancement" 'grep -q "\"MonOption\"[[:space:]]*\"7\"" "$vdf" && [[ -e $FAKE/gamescope.out ]]'
    check "sauvegarde .steamd.bak" '[[ -e $vdf.steamd.bak ]]'
    sed -i 's/"1"/"1"/' "$vdf"
    echo ENCODER=software >>"$CONF"
    launch
    check "ENCODER=software : EnableHardwareEncoding à 0" 'grep -q "\"EnableHardwareEncoding\"[[:space:]]*\"0\"" "$vdf"'
}

t_vaapi_env() {
    echo "== VAAPI_STRICT_RC : préchargement"
    reset "ENCODER=hardware" "VAAPI_STRICT_RC=true" "REFRESH=90"
    launch
    check "bibliothèque absente : avertissement, Steam lancé quand même" 'grep -q "libsteamd-vaapi.so introuvable" "$FAKE/launch.out" && [[ -e $FAKE/gamescope.out ]]'
    mkdir -p "$HOME/.local/share/steamd" && echo fausse >"$HOME/.local/share/steamd/libsteamd-vaapi.so"
    launch
    check "copiée sous STEAMD_HOME (visible du conteneur Steam)" '[[ -e $SD/.local/lib/steamd/libsteamd-vaapi.so ]]'
    check "LD_PRELOAD et STEAMD_VA_FPS=REFRESH" 'grep -q "^ENV LD_PRELOAD=$SD/.local/lib/steamd/libsteamd-vaapi.so" "$FAKE/gamescope.out" && grep -q "^ENV STEAMD_VA_FPS=90" "$FAKE/gamescope.out"'
    rm -f "$HOME/.local/share/steamd/libsteamd-vaapi.so"
}

t_audio() {
    echo "== AUDIO_ISOLATE"
    reset "AUDIO_ISOLATE=true"
    launch; launch; launch
    check "sortie créée une seule fois en trois lancements" '[[ $(grep -c load-module "$FAKE/pactl.log") == 1 ]]'
    check "sortie par défaut du bureau conservée" '[[ $(cat "$FAKE/default-sink") == speakers ]]'
    check "Steam envoyé sur la sortie et son moniteur" 'grep -q "^ENV PULSE_SINK=steamd" "$FAKE/gamescope.out" && grep -q "^ENV PULSE_SOURCE=steamd.monitor" "$FAKE/gamescope.out"'
    reset "AUDIO_ISOLATE=true"
    touch "$FAKE/pactl-ko"
    launch
    check "PipeWire injoignable : avertissement, Steam lancé sans isolation" '[[ $(code) == 0 ]] && grep -q "son non isolé" "$FAKE/launch.out" && ! grep -q PULSE_SINK "$FAKE/gamescope.out"'
    rm -f "$FAKE/pactl-ko"
    reset "AUDIO_ISOLATE=true" "AUDIO_SINK=stream"
    launch
    printf 'autre\n' >>"$FAKE/sinks"
    "$ROOT/bin/steamd-setup" --undo >/dev/null 2>&1
    check "steamd-setup --undo retire seulement sa sortie" '[[ $(cat "$FAKE/sinks") == autre ]]'
}

t_steamcfg() {
    echo "== steamd-steamcfg"
    local f="userdata/*/config/localconfig.vdf"
    reset
    export STEAMD_HOME=$SD
    check "get insensible à la casse" 'python3 "$CFG" get "$f" userlocalconfigstore/STREAMING/enablehardwareencoding | grep -q ": 0$"'
    check "set" 'python3 "$CFG" set "$f" UserLocalConfigStore/Streaming/Nouvelle 5 >/dev/null && python3 "$CFG" get "$f" UserLocalConfigStore/Streaming/Nouvelle | grep -q ": 5$"'
    check "check : relu à l'identique" 'python3 "$CFG" check >/dev/null'
    cp /bin/sleep "$FAKE/steam"
    HOME=/autre/bureau "$FAKE/steam" 30 &
    local desk=$!
    check "Steam du bureau en marche : écriture permise" 'python3 "$CFG" set "$f" UserLocalConfigStore/Streaming/Nouvelle 6 >/dev/null'
    HOME=$SD "$FAKE/steam" 30 &
    local mine=$!
    sleep 0.2
    python3 "$CFG" set "$f" UserLocalConfigStore/Streaming/Nouvelle 7 >/dev/null 2>&1
    check "Steam de steamd en marche : refus (code 3)" '[[ $? == 3 ]]'
    kill "$desk" "$mine" 2>/dev/null
    wait "$desk" "$mine" 2>/dev/null
    python3 "$CFG" snapshot >/dev/null
    python3 "$CFG" set "$f" UserLocalConfigStore/Streaming/EnableHardwareEncoding 1 >/dev/null
    check "diff : ligne STEAM_SETTINGS prête à copier" 'python3 "$CFG" diff | grep -qF "STEAM_SETTINGS+=(\"userdata/*/config/localconfig.vdf:UserLocalConfigStore/Streaming/EnableHardwareEncoding=1\")"'
    unset STEAMD_HOME
}

# steamd-profiled en tâche de fond, sur un faux Steam de steamd (pid dans le cgroup)
start_profiled() {
    sleep 300 &
    echo $! >"$FAKE/steampid"
    echo $! >"$FAKE/cg/steamd/cgroup.procs"
    "$PROFILED" 2>>"$FAKE/profiled.log" &
    PD=$!
}
stop_profiled() {
    kill "$PD" 2>/dev/null
    wait "$PD" 2>/dev/null
    kill "$(cat "$FAKE/steampid")" 2>/dev/null
}
start_game() {
    bash -c 'exec -a "reaper SteamLaunch AppId=620 --" sleep 300' &
    GAME=$!
    echo "$GAME" >>"$FAKE/cg/steamd/cgroup.procs"
}
stop_game() {
    kill "$GAME" 2>/dev/null
    cat "$FAKE/steampid" >"$FAKE/cg/steamd/cgroup.procs"
}
active_profile() { cat "$XDG_RUNTIME_DIR/steamd/profile" 2>/dev/null || echo default; }
restarts() { grep -c '^RESTART' "$FAKE/events" 2>/dev/null; }

t_profiled() {
    echo "== steamd-profiled : profil selon le client"
    reset "PROFILE_POLL=0.2" "PROFILE_REVERT_AFTER=1" "GAME_POWER_PROFILE=none" "INHIBIT_SLEEP_DURING_GAME=false" \
        'CLIENT_PROFILES=( "192.168.88.50 OUTPUT=3840x2160 REFRESH=60" )'
    : >"$FAKE/peers"
    start_profiled
    check "--clients : socket du Steam du bureau ignorée" '! "$PROFILED" --clients | grep -q 192.168.88.77'
    echo 192.168.88.50 >"$FAKE/peers"
    check "--clients : la TV apparaît avec son profil" '"$PROFILED" --clients | grep -q "profil correspondant : 192.168.88.50"'
    check "TV connectée : redémarrage dans son profil" 'wait_for "[[ \$(active_profile) == 192.168.88.50 ]]" 5'
    : >"$FAKE/peers"
    start_game
    sleep 1.5
    check "TV partie, partie en cours : pas de retour" '[[ $(active_profile) == 192.168.88.50 && $(restarts) == 1 ]]'
    stop_game
    check "partie finie : retour au défaut" 'wait_for "[[ \$(active_profile) == default ]]" 5'
    "$LAUNCH" --profile 192.168.88.50 >/dev/null
    check "demande manuelle appliquée" 'wait_for "[[ \$(active_profile) == 192.168.88.50 ]]" 5'
    check "demande retirée une fois appliquée" '[[ ! -e $XDG_RUNTIME_DIR/steamd/profile.request ]]'
    touch "$FAKE/inactive"
    local n
    n=$(restarts)
    "$LAUNCH" --profile default >/dev/null
    sleep 1
    check "steamd arrêté : aucun redémarrage" '[[ $(restarts) == "$n" ]]'
    stop_profiled
}

t_game() {
    echo "== steamd-profiled : veille et énergie pendant une partie"
    reset "PROFILE_POLL=0.2"
    start_profiled
    sleep 0.5
    start_game
    check "partie : profil d'énergie performance" 'wait_for "[[ \$(cat \$FAKE/power 2>/dev/null) == performance ]]" 5'
    check "partie : veille bloquée" 'pgrep -xf "sleep infinity" >/dev/null'
    stop_game
    check "fin de partie : profil balanced restauré" 'wait_for "[[ \$(cat \$FAKE/power) == balanced ]]" 5'
    check "fin de partie : veille libérée" 'wait_for "! pgrep -xf \"sleep infinity\" >/dev/null" 5'
    start_game
    wait_for '[[ $(cat "$FAKE/power") == performance ]]' 5
    stop_profiled
    check "service arrêté en pleine partie : profil restauré" '[[ $(cat "$FAKE/power") == balanced ]]'
    check "service arrêté en pleine partie : veille libérée" 'wait_for "! pgrep -xf \"sleep infinity\" >/dev/null" 3'
    kill "$GAME" 2>/dev/null
    reset "GAME_POWER_PROFILE=turbo"
    "$PROFILED" 2>/dev/null
    check "GAME_POWER_PROFILE invalide : code 2" '[[ $? == 2 ]]'
}

t_desktop() {
    echo "== Steam du bureau fermé au premier démarrage"
    reset "NETWORK_WAIT=0"
    mkdir -p "$HOME/.local/share/Steam/steamrt64"
    cp "$(command -v sleep)" "$HOME/.local/share/Steam/steamrt64/steam"
    "$HOME/.local/share/Steam/steamrt64/steam" 300 &
    wait_for 'pgrep -f "$HOME/.local/share/Steam/" >/dev/null' 3
    launch
    check "fermé par steam -shutdown avec le HOME du bureau" 'grep -q "^steam -shutdown HOME=$HOME$" "$FAKE/steam.log"'
    check "plus de Steam du bureau" 'wait_for "! pgrep -f \"$HOME/.local/share/Steam/\" >/dev/null" 3'
    "$HOME/.local/share/Steam/steamrt64/steam" 300 &
    launch
    check "relancé à la main : laissé ensuite" 'pgrep -f "$HOME/.local/share/Steam/" >/dev/null'
    check "un seul -shutdown" '[[ $(wc -l <"$FAKE/steam.log") == 1 ]]'
    kill %% 2>/dev/null
}

t_vaapi() {
    echo "== libsteamd-vaapi (fausse libva, chargée en RTLD_LOCAL comme dans Steam)"
    local inc=${VA_INCLUDE:-/usr/include} b=$FAKE/va
    if ! command -v cc >/dev/null || [[ ! -r $inc/va/va.h ]]; then
        skip "cc ou en-têtes libva absents (sudo pacman -S libva, ou VA_INCLUDE=...)"
        return
    fi
    mkdir -p "$b"
    if ! cc -O2 -Wall -Wextra -Werror -fPIC -shared -I"$inc" -o "$b/libsteamd-vaapi.so" "$ROOT/src/steamd-vaapi.c" -ldl -lpthread 2>"$b/cc.log"; then
        ko "compilation sans avertissement ($(head -1 "$b/cc.log"))"
        return
    fi
    ok "compilation sans avertissement"
    cc -I"$inc" -fPIC -shared -o "$b/libva.so.2" "$ROOT/tests/vaapi/fakeva.c" &&
        ln -sf libva.so.2 "$b/libva.so" &&
        cc -I"$inc" -fPIC -shared -o "$b/libenc.so" "$ROOT/tests/vaapi/enc.c" -L"$b" -lva -Wl,-rpath,"$b" &&
        cc -o "$b/host" "$ROOT/tests/vaapi/host.c" -ldl || { ko "banc de test compilé"; return; }
    LD_LIBRARY_PATH=$b "$b/host" "$b/libenc.so" >"$b/sans.out" 2>&1
    check "sans préchargement : VBR et HRD d'une seconde" 'grep -q "pilote RC=0x4" "$b/sans.out" && grep -q "pilote HRD=18000000" "$b/sans.out"'
    STEAMD_VA_DEBUG=1 STEAMD_VA_FPS=60 LD_LIBRARY_PATH=$b LD_PRELOAD=$b/libsteamd-vaapi.so "$b/host" "$b/libenc.so" >"$b/avec.out" 2>&1
    check "libva retrouvée malgré RTLD_LOCAL" '! grep -q introuvable "$b/avec.out"'
    check "VBR -> CBR pour le pilote" 'grep -q "pilote RC=0x2" "$b/avec.out"'
    check "l'appli garde sa propre valeur" 'grep -q "appli RC=0x4" "$b/avec.out"'
    check "HRD d'une image à 90 i/s (fréquence transmise)" '[[ $(grep -c "pilote HRD=200000 plein=150000" "$b/avec.out") == 2 ]]'
}

ALL=(launch config profiles tuning encoder vaapi_env audio steamcfg profiled game desktop vaapi)
for t in "${@:-${ALL[@]}}"; do
    if declare -F "t_$t" >/dev/null; then "t_$t"; else echo "test inconnu : $t (${ALL[*]})"; FAIL=$((FAIL + 1)); fi
done
echo
echo "$PASS OK, $FAIL KO, $SKIP sauté(s)"
((FAIL == 0))
