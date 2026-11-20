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
| `bin/steamd-launch` | Superviseur (ExecStart). États `running`, `busy`, `standby`, `backoff`, `stopped` écrits dans `$XDG_RUNTIME_DIR/steamd/state`. SIGUSR1 = réévaluation immédiate. Options `--print`, `--status`, `--handover`, `--apply-settings`. |
| `bin/steamd-session-hook` + `systemd/steamd-session-hook.service` | Rattaché à `graphical-session.target` (oneshot, avant le bureau) : réveille le superviseur à la connexion (attend `standby`/`busy`) et à la déconnexion. |
| `bin/steamd-doctor` | Diagnostic OK/KO/ATTENTION avec pistes. |
| `bin/steamd-steamcfg` | Python : lecture/écriture des VDF de Steam, snapshot/diff pour découvrir une clé. |
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
   `steamd-doctor` et traiter les KO.
2. **Options d'hôte Remote Play** : Steam fermé, `steamd-steamcfg snapshot` ;
   ouvrir Steam au bureau, changer les options d'hôte Remote Play
   (Paramètres > Remote Play > Options avancées de l'hôte), fermer Steam ;
   `steamd-steamcfg diff`. Ensuite, ajouter des **options nommées** dans
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
7. Dérouler le plan de test du README (tests 1 à 8, 6b à 6f).
8. **Résolution et fréquence par client** (demande de l'utilisateur, à
   concevoir) : il streame vers un Steam Deck (1280×800, 90 Hz) **et** une
   TV 4K (60 Hz), et veut une **détection automatique** plutôt que
   `WIDTH/HEIGHT/REFRESH` figés. La fréquence compte autant que la
   résolution (90 Hz capturés vers une TV à 60 Hz = saccades). gamescope
   headless fixe `-W/-H/-r` au démarrage. Investigations à faire d'abord :
   - streamer depuis le Deck puis depuis la TV, et lire
     `~/.steam/steam/logs/streaming_log.txt` (et `console_log.txt`) :
     nom du client, IP, résolution et fréquence demandées ?
   - gamescope en 3840×2160 + stream vers le Deck : la ligne `Capture` des
     statistiques du client montre-t-elle 3840×2160 ou 1280×800 (Steam
     réduit-il l'image côté hôte) ?
   - `gamescopectl` (si présent) : changer la résolution ou la fréquence
     headless à chaud, sans redémarrer gamescope ?
   - tester l'option d'hôte Steam « Adapter la résolution du bureau au
     client de streaming » dans gamescope headless (relever sa clé avec
     `steamd-steamcfg snapshot/diff`) : Steam ajuste-t-il seul la
     résolution de rendu selon le client ?
   Conclusions déjà tirées avec l'utilisateur :
   - **Pas de proxy Remote Play** : négociation chiffrée (clés d'appairage),
     Steam vit dans gamescope (relancer gamescope = relancer le serveur
     pendant que le client attend), et en VPN la mise en relation passe
     par les serveurs de Valve.
   - Le rendu 4K natif est hors de portée du PC : distinguer sortie
     (`-W/-H`, peu coûteuse) et rendu (`-w/-h`, ex. 1440p + FSR gamescope).
   - Plan retenu si l'option Steam ne suffit pas : **profils par client**
     (résolution de sortie, de rendu et fréquence). Le Deck annonce son
     profil au réveil (`wake-host.sh`, en SSH ou par un message réseau)
     pour éviter toute coupure. Les autres clients sont reconnus par leur IP
     à la connexion (LAN et IP WireGuard). En cas de changement de client,
     gamescope est relancé et la première connexion échoue (reconnexion
     30 à 60 s plus tard).
   - Règle 2 : ne jamais relancer gamescope pendant une partie.
   - Client TV : TV Samsung avec Steam Link pour Tizen
     (https://github.com/pebeto/tizen-steam-link), portage non officiel,
     aucun script possible côté TV : reconnaissance par IP (bail DHCP fixe
     sur le MikroTik). Limites de décodage inconnues (4K ? HEVC ?) : lire la
     résolution et le codec négociés dans l'affichage des performances de
     Steam Link sur la TV avant de fixer son profil.
   - Forme envisagée (non implémentée) :
     `CLIENT_PROFILES=("deck|1280x800|1280x800|90" "192.168.88.50|3840x2160|2560x1440|60")`
     (identifiant ou IP | sortie | rendu | fréquence).

## Propositions faites, sans réponse de l'utilisateur

- `wake-host.sh` qui passe par le Pi ou le MikroTik en SSH quand le Deck est
  hors du LAN (le broadcast ne traverse pas WireGuard).
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
  wifi/wifi-tune.sh tests/run.sh` et `tests/run.sh` (≈ 2 min, `idle` compris ;
  `tests/run.sh print login busy` pour un sous-ensemble).
- Style : bash avec tabulations, `set -euo pipefail`, messages en français,
  une piste de correction pour chaque erreur.
- Sur la vraie machine, déboguer avec :
  `journalctl --user -u steamd -u steamd-session-hook -f`,
  `steamd-launch --status`, `steamd-launch --print`, `steamd-doctor`.
- Le README est en français et suit les sections existantes ; le mettre à
  jour avec chaque fonctionnalité (y compris « État d'avancement » et le
  plan de test).
