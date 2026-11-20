# CLAUDE.md : passation pour reprendre steamd

Ce fichier est pour Claude Code, lancé sur le PC hôte (mode bureau). Il résume
l'état du projet, les décisions prises avec l'utilisateur et ce qui reste à
vérifier sur la vraie machine. Le README décrit le projet pour un humain ; ce
fichier dit **où on en est**.

Tous les échanges et les messages du code sont en **français**.

## Le projet en une phrase

Steam tourne en permanence dans un gamescope headless sous l'utilisateur (service
systemd utilisateur + linger), pour que le Steam Deck joue en Remote Play natif
sans écran ni session ouverte sur le PC, tout en cédant la place au Steam du
bureau quand quelqu'un utilise le PC.

## Contexte de l'utilisateur

- PC hôte : CachyOS, KDE Plasma 6 Wayland, AMD RX 9070 XT (RDNA4, RADV,
  encodage VA-API HEVC), **en Wi-Fi** pour le stream. Proton-CachyOS à jour.
- Client : Steam Deck (probablement OLED : capture affichée à 90 Hz).
- Réveil : Wake-on-LAN relayé par un Raspberry Pi vers l'Ethernet du PC
  (hors périmètre, fonctionne).
- Réseau : routeur MikroTik (RouterOS 7), VPN WireGuard pour jouer à
  l'extérieur. Le Wi-Fi monte sans session (SSH possible après WoL).
- Refus explicites : pas de Moonlight/Sunshine, **pas de Decky**, pas de
  Remote Play sans VPN (préférence sécurité), pas de « bureau client du
  headless via Steam Link » (latence jugée inacceptable).
- Sur un réseau peu fiable, l'utilisateur préfère jouer en natif sur le Deck
  (+ LSFG) : les pics Wi-Fi le gênent plus que la latence.

## Décisions de conception (à respecter)

1. **Service permanent** : `steamd.service` ne s'arrête jamais de lui-même
   (`Restart=always`, sauf code 2 = conf invalide).
2. **Une partie en cours n'est jamais interrompue**, quel que soit le Steam.
3. **Ne jamais tuer un Steam que steamd n'a pas lancé** (Steam du bureau,
   lancé à la main) : steamd attend en `standby`.
4. Politique par défaut `yield` : session graphique locale ouverte → Steam
   headless fermé, sauf partie Remote Play en cours (`busy`) → popup
   « Fermer la partie et ouvrir Steam ici / Attendre la fin », passage de
   main à la fin de la partie (`HANDOVER_DELAY`) et lancement du Steam du
   bureau. Session verrouillée = session ouverte (on n'y touche pas).
5. Les optimisations de jeu (`STREAM_TUNING`, `FPS_LIMIT`, `STEAM_ENV`) ne
   s'appliquent **qu'au Steam headless**, jamais au Steam du bureau. Les
   options de lancement par jeu restent prioritaires.
6. Les réglages Steam (`STEAM_SETTINGS`) ne sont écrits **que Steam fermé**
   (juste avant le lancement du Steam headless) ; jamais deviner une clé :
   la relever avec `steamd-steamcfg snapshot/diff`.
7. Pas de dépendance exotique : bash, systemd, Python stdlib (steamcfg).
8. `install.sh` / `uninstall.sh` idempotents ; uninstall ne retire que ce
   qu'install a ajouté (état dans `~/.local/share/steamd/install.state`).

## Architecture

| Fichier | Rôle |
|---|---|
| `bin/steamd-launch` | Superviseur (ExecStart). États `running`, `busy`, `standby`, `backoff`, `stopped` écrits dans `$XDG_RUNTIME_DIR/steamd/state` (ligne 2 : raison, avec `(profil X)`). SIGUSR1 = réévaluation immédiate. Options `--print [PROFIL]`, `--clients`, `--profile`, `--status`, `--handover`, `--apply-settings`. Profils par client (`CLIENT_PROFILES`). |
| `bin/steamd-session-hook` + `systemd/steamd-session-hook.service` | Rattaché à `graphical-session.target` (oneshot, avant le bureau) : réveille le superviseur à la connexion (attend `standby`/`busy`) et à la déconnexion. |
| `bin/steamd-doctor` | Diagnostic OK/KO/ATTENTION avec pistes. |
| `bin/steamd-steamcfg` | Python : lecture/écriture des VDF de Steam, snapshot/diff pour découvrir une clé. |
| `bin/steamd-probe` | Relevés sur la vraie machine : `rapport`, `options-remoteplay` (guidé), `clients` (IP en direct), `journal-stream`. Écrit des fichiers `~/steamd-*.txt`. |
| `systemd/steamd.service` | Unité utilisateur, `KillMode=mixed`, `TimeoutStopSec=60`. |
| `udev/60-steamd-uinput.rules` | `/dev/uinput` au groupe `input` (manettes sans session). |
| `polkit/60-steamd.rules` | Veille/extinction sans session + changement de profil d'énergie. |
| `desktop/steamd-handover.desktop` | Entrée de menu « Récupérer Steam ». |
| `deck/wake-host.sh` | Magic packet depuis le Deck. |
| `wifi/wifi-tune.sh` | Réglages Wi-Fi anti-pics (Deck et PC) via NetworkManager, sans Decky. |
| `tests/run.sh` + `tests/fake/` | Tests avec faux gamescope/Steam/logind/systemctl/notify-send/powerprofilesctl. |

Points techniques importants :
- Détection d'une partie : processus `reaper SteamLaunch AppId=N` dans le
  cgroup de `steamd.service` (ou le groupe de processus du fils hors systemd).
- Arrêt de Steam headless : `steam -shutdown`, `STOP_TIMEOUT`, SIGTERM puis
  SIGKILL sur le groupe (`setsid`), puis balayage du cgroup du service.
- Steam du bureau relancé via `systemd-run --user --slice=app.slice -p ExitType=cgroup`
  (hérite de l'environnement graphique importé par Plasma).
- Veille bloquée pendant une partie (`systemd-inhibit`), profil d'énergie
  `GAME_POWER_PROFILE` (power-profiles-daemon) pendant la partie, restauré.
- `IDLE_ACTION` (none par défaut) : compteur d'inactivité remis à zéro en
  sortie de veille (saut de temps détecté).

## Validé par l'utilisateur sur la vraie machine

- Le stream Remote Play depuis le Steam headless fonctionne.
- En VPN WireGuard depuis le Wi-Fi de son entreprise : 30 min jouables et
  stables, quelques pics dus au Wi-Fi de l'entreprise.
- Statistiques relevées (Borderlands 4) : `Capture 1280x800 @ 90`,
  `Desktop PipeWire NV12 DMABUF + VAAPI HEVC`, connexion directe
  `UDP@192.168.88.88` (IP LAN du PC, pas de relais), ping 5-6 ms, débit
  12-15 Mbit/s, latence d'affichage ~19 ms en VPN contre ~10 ms la veille
  (cause non établie : jeu lourd, VPN, Wi-Fi du PC, fragmentation).

Tout le reste n'a été testé qu'avec les faux de `tests/` : **à vérifier en vrai**.

## À faire devant le PC (dans l'ordre)

1. Mettre à jour : `git pull`, puis `./install.sh`. Installer au besoin
   `mangohud`, `libnotify`, `python`, `power-profiles-daemon`. Lancer
   `steamd-doctor` et traiter les KO. **Puis `steamd-probe rapport`** et lire
   le fichier produit : il répond d'un coup à beaucoup des questions
   ci-dessous (versions, options de gamescope, `gamescopectl`, couches
   Vulkan, Proton, journal de streaming).
2. **Options d'hôte Remote Play** : `steamd-probe options-remoteplay` (guidé :
   arrêt de steamd, snapshot, Steam ouvert pour changer les options, diff,
   relance). Ensuite, ajouter des **options nommées** dans
   `steamd-launch`/`steamd.conf` (ex. `REMOTEPLAY_PRIORITIZE_NETWORK=true`)
   qui se traduisent en entrées `STEAM_SETTINGS`, avec leurs vrais chemins
   de clés. L'utilisateur veut que steamd contrôle ces options sans afficher
   Steam.
3. Pendant une partie : `steamd-doctor` (ntsync réellement utilisé par
   `wineserver` ? couche Anti-Lag Mesa présente ?), `systemd-inhibit --list`,
   `powerprofilesctl get`.
4. Vérifier les hypothèses non testées :
   - `steam -shutdown` ferme bien le Steam headless (sans affichage) ;
   - la détection `reaper SteamLaunch AppId=` sur la version installée ;
   - la popup (boutons) dans Plasma depuis le service, le lancement du
     Steam du bureau après passage de main ;
   - le changement de profil d'énergie sans session (règle polkit, ids
     `org.freedesktop.UPower.PowerProfiles.switch-profile` /
     `net.hadess.PowerProfiles.switch-profile`) ;
   - le déclenchement de `steamd-session-hook` par Plasma 6.
5. Comparer Borderlands 4 : `STREAM_TUNING=true` puis `false`,
   `FPS_LIMIT=auto` (90) puis `45`, en regardant perte d'images et latence
   d'affichage. Pour Elden Ring (bloqué à 60) : `REFRESH=60`.
6. Wi-Fi : `wifi/wifi-tune.sh install` sur le Deck (mot de passe `deck` requis)
   et éventuellement sur le PC ; `wifi-tune.sh status`.
7. Dérouler le plan de test du README (tests 1 à 9, avec 6b à 6f, 7b, 9b et 9c).
8. **Résolution et fréquence par client** : **implémenté** (`CLIENT_PROFILES`,
   profil par défaut + exceptions par IP, choix de l'utilisateur), testé
   seulement avec un faux `ss` (`tests/run.sh profiles`). À valider :
   - `steamd-probe clients` pendant un stream depuis le Deck puis la TV :
     l'IP du client apparaît-elle parmi les sockets de `steam`
     (`ss -Htunp state established`) ? Sinon, adapter `client_peers` dans
     `steamd-launch` (autre nom de processus, sockets UDP non connectés :
     piste conntrack ou journal de streaming, voir `steamd-probe journal-stream`).
   - la reconnexion du client après le redémarrage de Steam headless, et
     le temps nécessaire (README, test 9) ;
   - d'abord tester l'option d'hôte « Adapter la résolution du bureau au
     client de streaming » (relevée par `steamd-probe options-remoteplay`) :
     si Steam ajuste seul le rendu dans gamescope, les profils ne servent
     plus qu'à la fréquence ;
   - la TV (Steam Link pour Tizen, https://github.com/pebeto/tizen-steam-link,
     aucun script possible) : bail DHCP fixe sur le MikroTik, puis lire la
     résolution et le codec négociés dans ses statistiques avant de fixer
     son profil (4K ? HEVC ?) ;
   - HDR (`HDR=true` dans un profil : `--hdr-enabled` + `DXVK_HDR=1`) :
     chaîne complète à valider (capture 10 bits, alors que les stats
     actuelles montrent `NV12` 8 bits ; Remote Play avec hôte Linux ; client
     Tizen). Si le format reste NV12 : retirer l'option.
   Conclusions tirées avec l'utilisateur : pas de proxy Remote Play
   (négociation chiffrée, Steam vit dans gamescope, en VPN la mise en
   relation passe par Valve) ; le rendu 4K natif est hors de portée du PC
   (distinguer `OUTPUT` et `RENDER`) ; règle 2 : jamais de relance de
   gamescope pendant une partie.
9. Réveil à travers le VPN : **implémenté** dans `deck/wake-host.sh`
   (`WAKE_SSH`, `WAKE_SSH_CMD`, `WAKE_SSH_MODE=auto`), testé avec un faux
   `ssh`. À configurer sur le Deck (clé SSH vers le MikroTik ou le Pi) et
   à tester (README, test 7b).

## Propositions faites, sans réponse de l'utilisateur

- Profils par jeu (ex. Elden Ring à 60 Hz, le reste à 90) : demanderait de
  relancer gamescope au changement de jeu.
- Fréquences GPU forcées pendant le stream (`power_dpm_force_performance_level`) :
  proposé, l'utilisateur ne l'a pas retenu.
- Fusion de `v1-implementation` dans `main` (PR ou fusion directe) : pas
  encore décidé. `main` ne contient que le README initial.

## Façon de travailler

- Branche de travail : `v1-implementation`. Ne pas pousser sur `main` sans
  accord.
- Avant chaque commit : `shellcheck -x bin/steamd-launch bin/steamd-doctor
  bin/steamd-session-hook install.sh uninstall.sh deck/wake-host.sh
  bin/steamd-probe wifi/wifi-tune.sh tests/run.sh` et `tests/run.sh` (≈ 3 min,
  `idle` compris ; `tests/run.sh print login busy profiles` pour un
  sous-ensemble).
- Style : bash avec tabulations, `set -euo pipefail`, messages en français,
  une piste de correction pour chaque erreur.
- Sur la vraie machine, déboguer avec :
  `journalctl --user -u steamd -u steamd-session-hook -f`,
  `steamd-launch --status`, `steamd-launch --print`, `steamd-doctor`.
- Le README est en français et suit les sections existantes ; le mettre à
  jour avec chaque fonctionnalité (y compris « État d'avancement » et le
  plan de test).
