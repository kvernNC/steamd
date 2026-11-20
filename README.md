# steamd

> Steam as a service, à la demande. Le PC fixe démarre sans écran ni session ouverte, Steam tourne dans un gamescope headless, et le Steam Deck joue via **Steam Remote Play natif**, sans Moonlight.

## Objectif

Permettre ce parcours, sans aucune intervention physique sur le PC hôte :

1. Sur le Steam Deck, lancer le raccourci « Réveil PC » en mode jeu.
2. Le PC se réveille (Wake-on-LAN relayé par un Raspberry Pi, déjà en place).
3. Au boot, sans connexion utilisateur, un service lance Steam dans gamescope en mode headless.
4. Sur le Deck, ouvrir la bibliothèque Steam, choisir un jeu, puis « Streamer depuis <hôte> ».
5. Aucun écran physique ni virtuel n'est utilisé côté OS : c'est gamescope qui sert de surface de présentation, et Remote Play capture sa sortie via PipeWire.

## Contexte matériel et logiciel

| Élément | Valeur |
|---|---|
| Hôte | PC fixe, CachyOS (base Arch), KDE Plasma / Wayland |
| GPU | AMD Radeon RX 9070 XT (mesa / RADV, encodage VA-API) |
| Réseau hôte | Wi-Fi pour le stream ; Ethernet de la carte mère relié à un Raspberry Pi pour le WoL |
| Relais WoL | Raspberry Pi B+ allumé en permanence. Il écoute les magic packets sur le LAN et retraduit ceux destinés au PC vers la MAC Ethernet. **Hors du périmètre de ce repo.** |
| Client | Steam Deck (SteamOS), Steam Remote Play natif |
| Steam hôte | Installation native (paquet `steam`). Même utilisateur et même `~/.steam` que l'usage bureau : **pas de seconde installation ni de bibliothèque en double**. |

## Périmètre

### Inclus

- Service systemd **utilisateur** `steamd.service`, **permanent** (*always on*), qui supervise `gamescope --backend headless` avec Steam en Big Picture.
- Activation du *linger* pour que le service démarre au boot sans session.
- Dépendances PipeWire et WirePlumber en services utilisateur (vidéo et audio sans session graphique).
- Règle udev donnant l'accès à `/dev/uinput` sans session active (manettes virtuelles du Remote Play), par exemple via le groupe `input`.
- Gestion du conflit avec une session de bureau : un seul Steam à la fois, et **une partie en cours n'est jamais interrompue**, quel que soit le Steam qui la fait tourner. Le Steam du bureau n'est jamais coupé. Si quelqu'un se connecte pendant une partie Remote Play, la partie continue et le bureau récupère Steam à la fin. Ce comportement est configurable.
- Gestion de l'énergie : veille bloquée pendant une partie Remote Play. En option, mise en veille ou extinction du PC quand il tourne sans session ni partie.
- Fichier de configuration simple : résolution, fréquence et options gamescope/Steam.
- Script d'installation et de désinstallation idempotent.
- Côté Deck : script de réveil (`wake-host.sh`) à ajouter comme raccourci non-Steam en mode jeu.
- Script de diagnostic qui vérifie linger, PipeWire, les droits sur `/dev/dri` et `/dev/uinput`, et l'état du service, puis affiche les derniers logs.

### Exclus

- Moonlight, Sunshine, Wolf et tout serveur de streaming tiers.
- Le relais WoL du Raspberry Pi, déjà fonctionnel.
- Le multi-utilisateur et les sessions simultanées.
- Docker ou Podman. Pas de conteneur dans la v1 : Steam tourne nativement sous l'utilisateur.

## Arborescence cible

```
steamd/
├── README.md
├── config/
│   └── steamd.conf.example     # résolution, fréquence, options
├── systemd/
│   ├── steamd.service              # unité utilisateur
│   └── steamd-session-hook.service # suit graphical-session.target
├── udev/
│   └── 60-steamd-uinput.rules
├── polkit/
│   └── 60-steamd.rules         # veille / extinction sans session
├── desktop/
│   └── steamd-handover.desktop # entrée de menu « Récupérer Steam »
├── bin/
│   ├── steamd-launch           # wrapper : lit la conf, lance gamescope et Steam
│   ├── steamd-doctor           # diagnostic
│   ├── steamd-steamcfg         # lit et modifie les réglages de Steam (Python)
│   ├── steamd-probe            # relevés sur la vraie machine (rapport, options, clients)
│   └── steamd-session-hook     # arrêt et reprise selon la session locale
├── deck/
│   └── wake-host.sh            # envoi du magic packet depuis le Deck
├── wifi/
│   └── wifi-tune.sh            # réglages Wi-Fi anti-pics, Deck et PC (sans Decky)
├── tests/
│   ├── run.sh                  # tests du superviseur et de steamd-steamcfg
│   └── fake/                   # faux gamescope, Steam, logind, systemctl...
├── CLAUDE.md                   # passation : état du projet et reste à faire
├── install.sh
└── uninstall.sh
```

## Commande de référence

Point de départ à valider manuellement avant toute automatisation :

```bash
gamescope -W 1280 -H 800 -w 1280 -h 800 -r 60 \
  --backend headless --steam -- \
  steam -tenfoot -pipewire-dmabuf
```

- `-W`/`-H` : résolution de sortie de gamescope. `-w`/`-h` : résolution vue par l'application. On utilise 1280×800, la résolution native du Deck.
- Plan B en cas d'écran noir : remplacer `-pipewire-dmabuf` par `-pipewire`, puis retirer l'option. Le wrapper doit permettre de changer ce choix dans la conf.

## Installation

Sur le PC hôte, avec l'utilisateur qui joue (pas en root, `sudo` est demandé quand il faut) :

```bash
git clone https://github.com/kvernNC/steamd.git
```

```bash
cd steamd && ./install.sh
```

Ce que fait `install.sh` (relançable sans risque) :

| Étape | Détail |
|---|---|
| Scripts | `steamd-launch`, `steamd-doctor`, `steamd-session-hook` et `steamd-steamcfg` dans `~/.local/bin` |
| Unités | `steamd.service` et `steamd-session-hook.service` dans `~/.config/systemd/user`, activées |
| Configuration | `~/.config/steamd/steamd.conf` copié depuis l'exemple, **seulement s'il n'existe pas** |
| udev | `/etc/udev/rules.d/60-steamd-uinput.rules` (groupe `input` par défaut, `--group NOM` pour changer) |
| Module | `/etc/modules-load.d/steamd-uinput.conf` pour charger `uinput` au boot |
| Menu | entrée « Récupérer Steam (steamd) » dans `~/.local/share/applications` (même effet que le bouton de la popup) |
| polkit | `/etc/polkit-1/rules.d/60-steamd.rules` : autorise l'utilisateur à mettre en veille ou éteindre le PC sans session (`IDLE_ACTION`), et à changer de profil d'énergie (`GAME_POWER_PROFILE`) |
| Groupe | ajoute l'utilisateur au groupe, s'il n'y est pas déjà |
| Linger | `loginctl enable-linger $USER`, s'il n'est pas déjà activé |
| PipeWire | `pipewire.socket`, `pipewire-pulse.socket` et `wireplumber.service` activés en utilisateur |

Ce que l'installation a elle-même changé (groupe, linger) est noté dans `~/.local/share/steamd/install.state`. C'est ce qui permet à `uninstall.sh` de ne retirer que ce qui a été ajouté.

Le service est activé et démarré tout de suite. C'est sans risque pendant une session de bureau : il reste en veille et ne touche pas au Steam ouvert. Options : `--no-enable` (ne pas activer au boot) et `--no-start` (ne pas démarrer maintenant).

Ensuite : faire les [prérequis manuels](#prérequis-manuels-une-seule-fois), puis **redémarrer**. Le gestionnaire systemd utilisateur ne prend le nouveau groupe qu'à son redémarrage.

## Configuration (`~/.config/steamd/steamd.conf`)

```ini
WIDTH=1280
HEIGHT=800
REFRESH=60
APP_WIDTH=""                    # vide = WIDTH
APP_HEIGHT=""                   # vide = HEIGHT
HDR=false                       # à valider de bout en bout (voir Profils par client)
CLIENT_PROFILES=()              # exceptions par IP : résolution, rendu, fréquence, HDR
PROFILE_REVERT_AFTER=600        # retour au profil par défaut sans ce client
STEAM_CAPTURE=pipewire-dmabuf   # pipewire-dmabuf | pipewire | none
STEAM_UI_ARG="-tenfoot"         # ou -gamepadui
GAMESCOPE_EXTRA_ARGS=""
STEAM_EXTRA_ARGS=""
STREAM_TUNING=true              # optimisations stream pour tous les jeux de Steam headless
FPS_LIMIT=auto                  # auto (= REFRESH) | 0 | N
FPS_LIMIT_METHOD=mangohud       # mangohud | dxvk
FPS_LIMIT_TIMING=late           # late (latence) | early (régularité), avec MangoHud
STEAM_ENV=()                    # variables supplémentaires pour tous les jeux
STEAM_SETTINGS=()               # réglages de Steam écrits avant chaque lancement
DESKTOP_SESSION_POLICY=yield    # yield | takeover
HANDOVER_DELAY=15               # après une partie, délai avant de rendre Steam au bureau
RESUME_DESKTOP_STEAM=true       # lancer le Steam du bureau après le passage de main
DESKTOP_STEAM_ARGS=""           # ex. "-silent"
NOTIFY=true                     # notifications sur le bureau (libnotify)
INHIBIT_SLEEP_DURING_GAME=true  # bloquer la veille pendant une partie Remote Play
IDLE_ACTION=none                # none | suspend | poweroff, sans session ni partie
IDLE_TIMEOUT=1800               # au bout de 30 min
POLL_INTERVAL=5                 # intervalle entre deux vérifications
RESTART_DELAY=10                # délai de relance après une fin inattendue
STOP_TIMEOUT=30                 # temps laissé à Steam pour se fermer proprement
```

Le fichier est lu par bash. Les options `*_EXTRA_ARGS` sont découpées sur les espaces, sans gestion des guillemets imbriqués. La liste complète est commentée dans [`config/steamd.conf.example`](config/steamd.conf.example).

Pour voir la commande qui sera lancée, sans rien démarrer :

```bash
steamd-launch --print
```

Après une modification :

```bash
systemctl --user restart steamd
```

### Jeux optimisés pour le stream

Tous les jeux lancés par le Steam headless reçoivent des réglages pensés pour le stream. Ils passent par l'environnement de Steam headless, donc **jamais au Steam du bureau**. Les options de lancement d'un jeu dans Steam (`VAR=... %command%`) restent prioritaires pour ce jeu.

| Réglage | Par défaut | Effet |
|---|---|---|
| `STREAM_TUNING=true` | actif | `DXVK_CONFIG=dxgi.maxFrameLatency=1;d3d9.maxFrameLatency=1` : une image préparée d'avance au lieu de 3, donc moins de latence. `PROTON_DXVK_LOWLATENCY=1` et `PROTON_VKD3D_LOWLATENCY=1` : variantes « low latency » de DXVK et VKD3D-Proton propres à [Proton-CachyOS](https://github.com/CachyOS/proton-cachyos), pour un meilleur rythme d'images, ignorées par les autres versions de Proton. `ENABLE_LAYER_MESA_ANTI_LAG=1` : Anti-Lag d'AMD fourni par Mesa, moins de latence dans les jeux qui l'utilisent, ignoré sinon. ntsync n'a pas besoin de réglage : il est actif par défaut dans les Proton récents (`PROTON_NO_NTSYNC=1` le désactiverait) |
| `FPS_LIMIT=auto` | = `REFRESH` | Plafond calé sur la fréquence de capture : le GPU garde de la marge pour capturer et encoder, et les images partent régulièrement. Pour un jeu lourd qui ne tient pas `REFRESH`, un sous-multiple (45 pour 90) est plus fluide qu'un rythme irrégulier |
| `FPS_LIMIT_METHOD=mangohud` | MangoHud | Couche Vulkan invisible (paquet `mangohud`), qui couvre les jeux natifs comme ceux sous Proton. `dxvk` : limiteurs de DXVK et VKD3D-Proton, sans MangoHud. Repli automatique sur `dxvk` si MangoHud est absent |
| `FPS_LIMIT_TIMING=late` | late | Avec MangoHud : `late` donne la latence la plus basse, `early` des intervalles plus réguliers |
| `GAME_POWER_PROFILE=performance` | performance | Profil d'énergie (power-profiles-daemon) pendant une partie Remote Play, rétabli à la fin. Équivalent de `game-performance` de CachyOS, mais limité à la durée de la partie ; `none` pour ne rien changer |
| `STEAM_ENV=(...)` | vide | Variables supplémentaires (`NOM=valeur`) pour tous les jeux. Elles passent en dernier et remplacent les précédentes si le nom est le même, par exemple `"PROTON_DXVK_LOWLATENCY=0"` pour retirer un réglage |

Plusieurs de ces variables sont repérées grâce à [GOverlay](https://github.com/benjamimgois/goverlay) et à la documentation de [Proton-CachyOS](https://github.com/CachyOS/proton-cachyos).

À essayer dans `STEAM_ENV` avec Proton-CachyOS et une carte RDNA4 : `PROTON_FSR4_UPGRADE=1` remplace FSR 3.1 par FSR 4 dans les jeux compatibles. Avec un upscaler en mode qualité, le GPU travaille moins et garde de la marge pour l'encodage dans les jeux lourds.

`steamd-launch --print` affiche l'environnement exact donné aux jeux. `steamd-doctor` vérifie MangoHud et l'accès à `/dev/ntsync`. Il lit aussi le script de chaque version de Proton installée (Proton-CachyOS, GE-Proton, Proton officiel) pour indiquer quelle variable pilote ntsync. Pendant une partie, il confirme que le `wineserver` a bien ouvert `/dev/ntsync`.

### Profils par client

Les réglages `WIDTH`, `HEIGHT`, `APP_WIDTH`, `APP_HEIGHT`, `REFRESH` et `HDR` forment le **profil par défaut**, celui du Steam Deck par exemple. Certaines IP peuvent avoir leur propre profil, par exemple une TV 4K à 60 Hz :

```bash
CLIENT_PROFILES=(
	"192.168.88.50 OUTPUT=3840x2160 RENDER=2560x1440 REFRESH=60"
)
```

| Clé | Rôle |
|---|---|
| `OUTPUT=LxH` | sortie de gamescope (`-W/-H`), c'est-à-dire l'image capturée. Peu coûteuse |
| `RENDER=LxH` | résolution de rendu du jeu (`-w/-h`), ce qui pèse sur le GPU ; gamescope agrandit l'image jusqu'à la sortie. Sans `RENDER`, le rendu est égal à la sortie |
| `REFRESH=N` | fréquence de gamescope, donc de la capture. Elle doit correspondre à l'écran du client (60 pour une TV), sinon l'image saccade |
| `HDR=true` | `--hdr-enabled` dans gamescope et `DXVK_HDR=1` pour les jeux. À valider : si les statistiques du client montrent toujours `NV12` (8 bits), le HDR ne passe pas |
| `FPS_LIMIT=N` | limite propre au profil (sinon `auto`, égale à `REFRESH`) |

Les clés absentes reprennent le profil par défaut. Plusieurs IP peuvent partager un profil (`"192.168.88.50,10.8.0.5 ..."`), utile pour un client qui passe aussi par WireGuard.

- **Détection :** `steamd` regarde les IP connectées aux sockets de Steam, sans proxy ni droits root.
- **Changement de profil :** quand un client du profil se connecte, Steam headless redémarre avec ce profil. La première connexion de ce client échoue ; il faut se reconnecter 30 à 60 secondes plus tard. **Jamais pendant une partie.**
- **Retour au profil par défaut :** après `PROFILE_REVERT_AFTER` secondes sans ce client (10 minutes par défaut). Le client par défaut retrouve ainsi son profil sans coupure.
- **Changement manuel :** `steamd-launch --profile 192.168.88.50`, ou `--profile default`.
- **Vérifier :** `steamd-launch --clients` affiche les IP connectées et le profil correspondant ; `steamd-launch --print 192.168.88.50` affiche la commande d'un profil.

Si l'option d'hôte de Steam « Adapter la résolution du bureau au client de streaming » suffit dans gamescope, ces profils ne servent plus qu'à la fréquence. C'est à vérifier sur la vraie machine.

### Réglages de Steam pilotés par `steamd`

Pour éviter d'ouvrir l'interface de Steam, `steamd` peut écrire lui-même des réglages dans les fichiers de configuration de Steam, par exemple les options d'hôte Remote Play. Il le fait juste avant chaque lancement du Steam headless, quand Steam est fermé et ne peut donc pas les écraser. Ces fichiers sont ceux de ton compte : les réglages valent aussi pour le Steam du bureau.

```bash
STEAM_SETTINGS=(
	"userdata/*/config/localconfig.vdf:UserLocalConfigStore/Chemin/Vers/Option=1"
)
```

Les noms des clés ne sont pas documentés par Valve. Pour trouver celle d'une option, une fois, depuis le bureau :

1. Fermer Steam complètement, puis photographier les réglages :

   ```bash
   steamd-steamcfg snapshot
   ```

2. Ouvrir Steam, changer l'option, puis fermer Steam complètement.
3. Afficher ce qui a changé, avec les lignes prêtes à copier dans `STEAM_SETTINGS` :

   ```bash
   steamd-steamcfg diff
   ```

Pour appliquer les réglages tout de suite, Steam fermé :

```bash
steamd-launch --apply-settings
```

`steamd-steamcfg get FICHIER CLÉ` affiche une valeur. Chaque fichier modifié est d'abord sauvegardé à côté, sous le nom `*.steamd.bak`. `steamd-doctor` indique pour chaque réglage s'il est déjà appliqué.

## Fonctionnement

`steamd.service` est un service **permanent** : activé au boot, il ne s'arrête jamais de lui-même (`Restart=always`). Il exécute `steamd-launch`, un superviseur qui réévalue la situation toutes les `POLL_INTERVAL` secondes :

**Règle de base : une partie en cours n'est jamais interrompue, quel que soit le Steam qui la fait tourner.** Chaque jeu lancé par Steam passe par un processus `reaper SteamLaunch AppId=…`, c'est ainsi que `steamd` repère une partie.

| Situation | État | Action |
|---|---|---|
| Personne sur le PC, aucun autre Steam | `running` | Steam headless lancé dans gamescope (et relancé s'il plante) |
| Connexion au bureau, pas de partie Remote Play | `standby` | Steam headless fermé proprement *avant* le démarrage du bureau ; le Steam du bureau démarre normalement |
| Connexion au bureau **pendant une partie Remote Play** | `busy` | La partie continue. Une popup s'affiche sur le bureau : « Steam est utilisé en Remote Play (jeu X), il s'ouvrira ici à la fin de la partie », avec deux boutons, **Fermer la partie et ouvrir Steam ici** et **Attendre la fin**. Sans clic, `HANDOVER_DELAY` secondes après la fin de la partie, Steam headless est fermé et le Steam du bureau lancé |
| Jeu lancé au bureau, absence, session verrouillée | `standby` | Rien ne change : une session verrouillée reste ouverte, la partie continue. La mise en veille éventuelle relève de KDE |
| Un Steam lancé hors de steamd tourne encore (bureau, terminal…) | `standby` | **jamais tué** : steamd attend qu'il se ferme, puis reprend la main |
| Partie Remote Play en cours | `running`/`busy` | Mise en veille du PC bloquée (`systemd-inhibit`), y compris celle de KDE |
| Aucune session (ni bureau, ni SSH) et aucune partie depuis `IDLE_TIMEOUT` | `running` | `IDLE_ACTION` : rien (défaut), mise en veille ou extinction |
| Fin inattendue de gamescope ou de Steam | `backoff` | relance après `RESTART_DELAY` × nombre d'échecs rapprochés (300 s max) |

Limite : `steamd` sait repérer un **jeu lancé**, pas un stream ouvert sur le menu de Big Picture sans jeu. Dans ce cas, une connexion au bureau reprend la main tout de suite, sans qu'aucune partie soit perdue.

- **Politique `takeover`** : Steam headless reste actif même pendant une session de bureau. Le Steam du bureau s'ouvre alors *dans* l'instance headless, invisible à l'écran. C'est utile seulement si le PC sert surtout de serveur.
- **`steamd-session-hook.service`** est rattaché à `graphical-session.target`, que Plasma démarre à la connexion. À la connexion, il s'exécute *avant* le bureau (`Type=oneshot`, donc bloquant) : il réveille le superviseur (SIGUSR1) et attend qu'il soit en veille, ou en `busy` si une partie Remote Play est en cours. Le Steam du bureau démarre ensuite normalement. À la déconnexion, il réveille le superviseur pour une reprise immédiate. Une connexion SSH n'ouvre pas de session graphique et n'a aucun effet.
- **Arrêt de Steam headless** : `steam -shutdown`, puis `STOP_TIMEOUT` secondes de délai, puis SIGTERM et enfin SIGKILL sur le groupe de processus gamescope. Un dernier balayage du cgroup du service garantit qu'aucun reste ne survit à la mise en veille.
- **Steam du bureau relancé par steamd** : il démarre dans une unité transitoire (`systemd-run --user`, `app.slice`) qui hérite de l'environnement graphique importé par Plasma.
- **Veille et extinction sans session** : un utilisateur sans session active n'a pas le droit de mettre le PC en veille. La règle polkit installée par `install.sh` le lui accorde. Le compteur d'inactivité repart de zéro à chaque sortie de veille.
- **Environnement** : `DISPLAY` et `WAYLAND_DISPLAY` hérités d'une ancienne session Plasma sont retirés avant de lancer gamescope.
- **Code de sortie `2`** : configuration invalide. C'est le seul cas où systemd ne relance pas le service.

Pour récupérer Steam sur le bureau sans attendre la fin de la partie Remote Play, si la popup a été fermée : l'entrée de menu « Récupérer Steam (steamd) », ou la commande ci-dessous. La partie en cours est fermée, et la progression non sauvegardée du joueur à distance est perdue.

```bash
steamd-launch --handover
```

L'état courant (`running`, `busy`, `standby`, `backoff`, `stopped`) et sa raison s'affichent avec :

```bash
steamd-launch --status
```

### Commandes utiles

```bash
systemctl --user status steamd
```

```bash
journalctl --user -u steamd -f
```

```bash
systemctl --user restart steamd
```

En SSH, si `systemctl --user` répond « Failed to connect to bus » : `export XDG_RUNTIME_DIR=/run/user/$(id -u)`.

## Diagnostic

```bash
steamd-doctor
```

Le diagnostic vérifie : les binaires et le backend headless de gamescope, les fichiers installés et la validité de la conf, le linger, PipeWire et WirePlumber, `/dev/dri/renderD*` et l'encodage VA-API (si `vainfo` est présent), `/dev/uinput` (module, règle udev, groupe du nœud, appartenance de l'utilisateur et du gestionnaire systemd au groupe), le compte Steam, l'état du superviseur et l'instance unique, le hook de session, le pare-feu et l'état du service. Il affiche ensuite les derniers logs.

Chaque point est marqué `OK`, `KO` ou `ATTENTION`, avec une piste de correction. Le code de sortie est le nombre de `KO`. Options : `-n 100` pour afficher plus de logs, `--no-logs` pour ne pas les afficher.

### Relevés sur la vraie machine : `steamd-probe`

`steamd-probe` collecte en une commande les informations utiles au réglage et au débogage. Chaque commande écrit un fichier texte dans le dossier personnel, à transmettre tel quel.

| Commande | Ce qu'elle fait |
|---|---|
| `steamd-probe rapport` | Rapport complet : versions des paquets, options utiles de gamescope et `gamescopectl`, état de `steamd`, `steamd-doctor`, couches Vulkan, versions de Proton, partie en cours (ntsync, blocage de veille, profil d'énergie), Wi-Fi, journal de streaming de Steam, journal de `steamd` |
| `steamd-probe options-remoteplay` | Relevé guidé des clés des options Remote Play : arrête `steamd`, photographie les réglages, ouvre Steam pour que tu changes les options, puis affiche les clés modifiées et relance `steamd` |
| `steamd-probe clients` | Suivi en direct des IP connectées au Steam headless et du profil choisi. Sert à trouver l'IP de la TV et à vérifier la détection |
| `steamd-probe journal-stream` | Extrait du journal de streaming de Steam (client, résolution, codec, HDR). À lancer après une session depuis chaque client |

## Désinstallation

```bash
./uninstall.sh
```

Le script arrête et désactive les services, puis supprime les scripts, les unités, la règle udev et le fichier `modules-load`. Par défaut, il conserve :

- la configuration (`--purge` pour la supprimer) ;
- le groupe (`--remove-group`) et le linger (`--disable-linger`). Avec ces options, ils ne sont retirés que si `install.sh` les avait lui-même ajoutés. `--force` les retire dans tous les cas.

Steam, `~/.steam` et les bibliothèques de jeux ne sont jamais touchés.

## Exigences techniques

1. **Sans session** : le service doit fonctionner après un boot à froid, sans connexion à SDDM. On le vérifie en redémarrant puis en se connectant uniquement en SSH.
2. **Linger** : `loginctl enable-linger $USER`, géré par `install.sh`.
3. **PipeWire** : `pipewire.socket`, `pipewire-pulse.socket` et `wireplumber.service` activés en utilisateur. `steamd.service` doit être ordonné après eux.
4. **GPU** : vérifier l'accès à `/dev/dri/renderD*` sans session. Normalement ouvert, mais le diagnostic doit le contrôler.
5. **Entrées** : sans session, `uaccess` ne s'applique pas. Il faut une règle udev qui ouvre `/dev/uinput` à un groupe dont l'utilisateur fait partie. `install.sh` ajoute l'utilisateur au groupe et recharge udev.
6. **Instance unique** : ne jamais laisser deux Steam tourner pour le même utilisateur. `steamd` passe en veille à l'ouverture d'une session graphique locale et ne tue jamais un Steam qu'il n'a pas lancé.
7. **Robustesse** : service permanent (`Restart=always`) ; Steam headless relancé avec un délai croissant en cas de plantage. Les logs sont lisibles via `journalctl --user -u steamd`.
8. **Idempotence** : `install.sh` et `uninstall.sh` peuvent être relancés sans effet de bord. `uninstall.sh` retire tout ce que `install.sh` a ajouté (unité, règle udev, groupe en option, linger en option).

## Côté Steam Deck

- `deck/wake-host.sh` envoie un magic packet en broadcast sur le LAN (MAC et broadcast configurables en tête de script). Sans dépendance exotique : Python stdlib ou `wakeonlan` s'il est présent.
- L'ajouter en jeu non-Steam depuis le mode bureau, pour pouvoir le lancer depuis le mode jeu.
- Le Pi se charge de la traduction vers la carte Ethernet du PC.

Mise en place, en mode bureau sur le Deck :

1. Copier `deck/wake-host.sh` (par exemple dans `~/bin/`), puis `chmod +x`.
2. Renseigner `HOST_MAC` (la MAC qu'attend le relais) et `BROADCAST` en tête du script, ou dans `~/.config/steamd/wake-host.conf`.
3. Facultatif : définir `HOST_ADDR` pour que le script attende que le PC réponde au ping (jusqu'à `WAIT_TIMEOUT`).
4. Steam > *Ajouter un jeu non-Steam* > choisir le script, puis le renommer « Réveil PC ».

Le mode jeu n'affiche rien : chaque envoi est journalisé dans `~/.local/state/steamd/wake-host.log`.

**À travers le VPN WireGuard,** le broadcast du magic packet ne traverse pas le tunnel. `wake-host.sh` peut alors demander à une machine du LAN de l'envoyer, en SSH par clé :

```bash
WAKE_SSH="admin@192.168.88.1"
WAKE_SSH_CMD="/tool wol interface=bridge mac={MAC}"
WAKE_SSH_MODE=auto
```

- `WAKE_SSH` : la machine relais. L'exemple est un MikroTik ; pour le Raspberry Pi, `WAKE_SSH_CMD="wakeonlan {MAC}"`.
- `WAKE_SSH_MODE` : en `auto`, le SSH n'est utilisé que si un tunnel WireGuard est actif. Les autres valeurs sont `always` et `never`.
- **Clé SSH :** le mode jeu ne peut pas demander de mot de passe. Il faut donc une clé SSH du Deck autorisée sur le relais. Pour en créer une :

  ```bash
  ssh-keygen -t ed25519
  ```

  Pour l'autoriser sur le Pi :

  ```bash
  ssh-copy-id pi@192.168.88.2
  ```

  Sur le MikroTik, importe la clé publique avec `/user ssh-keys import`.

## Wi-Fi : réduire les pics de latence

La plupart des pics pendant un stream viennent du Wi-Fi lui-même, en particulier de son économie d'énergie : la carte s'endort entre deux paquets et se réveille en retard. `wifi/wifi-tune.sh` corrige ça **sans Decky**, en passant par NetworkManager. Il fonctionne sur le Deck (SteamOS) comme sur le PC hôte (CachyOS). Il est inspiré des réglages du plugin Decky [WifiOptimizer](https://github.com/ArcadaLabs-Jason/WifiOptimizer).

Pour l'installer :

```bash
./wifi/wifi-tune.sh install
```

Pour voir l'état du Wi-Fi et des réglages :

```bash
./wifi/wifi-tune.sh status
```

| Réglage | Quand |
|---|---|
| Économie d'énergie du Wi-Fi désactivée (NetworkManager et `iw`) | tout de suite, puis à chaque connexion |
| États d'économie d'énergie PCIe (ASPM) de la carte Wi-Fi désactivés | tout de suite, puis à chaque connexion |
| Tampons réseau agrandis (rafales du stream), file d'émission allongée | tout de suite, puis à chaque connexion |
| Options du pilote : rtw88 du Deck LCD, rtw89, mt7921e, iwlwifi. Rien à faire pour ath11k du Deck OLED | au prochain démarrage |

- **Réapplication automatique :** un script de NetworkManager remet ces réglages à chaque connexion Wi-Fi, y compris après une mise en veille.
- **Mises à jour de SteamOS :** les fichiers sont dans `/etc`, conservé lors des mises à jour.
- **Mot de passe :** sur le Deck, `sudo` demande que le mot de passe de l'utilisateur `deck` soit défini (`passwd`).
- **Retour en arrière :** `./wifi/wifi-tune.sh uninstall` retire tout et restaure les tampons d'origine. Un redémarrage revient complètement aux réglages d'origine.

En option, `./wifi/wifi-tune.sh lock-ap` verrouille le réseau Wi-Fi actuel sur son point d'accès actuel. Le Deck ne cherche alors plus d'autre point d'accès en arrière-plan, ce qui supprime une autre source de pics. La contrepartie : si ce point d'accès disparaît (autre pièce, autre bâtiment), le Deck ne se reconnecte plus à ce réseau. Pour défaire le verrouillage : `unlock-ap`. C'est à réserver au réseau de la maison ; à éviter sur un réseau d'entreprise avec plusieurs bornes.

Le plugin propose d'autres réglages que je n'ai pas repris, parce qu'ils peuvent empêcher la connexion ou n'aident pas le stream : bande forcée, DNS, IPv6, WPA2, changement de backend Wi-Fi, file d'attente CAKE.

Côté PC, `steamd-doctor` signale une économie d'énergie Wi-Fi active. Le meilleur remède côté PC reste l'Ethernet.

## Routeur MikroTik (RouterOS 7)

Réglages utiles pour jouer à distance à travers WireGuard. Ces commandes sont à adapter : remplace `wireguard1`, `bridge`, `ether1`, les adresses et les débits par les tiens. Elles n'ont pas été vérifiées sur toutes les versions de RouterOS ; relis ta configuration avant de les appliquer (`/export`).

### WireGuard : accès du VPN au PC

Le Deck doit pouvoir joindre le PC à travers le tunnel, et pas seulement Internet. La règle ci-dessous autorise le trafic du VPN vers le LAN. Elle doit passer **avant** les règles qui bloquent, d'où le `place-before=0` (en tête de liste).

```bash
/ip firewall filter add chain=forward in-interface=wireguard1 out-interface=bridge action=accept comment="steamd: WireGuard vers LAN" place-before=0
```

Pour vérifier, avec le VPN actif sur le Deck :

```bash
ping -c3 192.168.88.10
```

Pendant un stream, l'affichage des performances doit indiquer une IP du LAN (connexion directe), pas un relais de Valve.

La découverte de Remote Play se fait par broadcast, qui ne traverse pas WireGuard. Le Deck trouve quand même le PC par le compte Steam, après un délai qui peut aller jusqu'à une ou deux minutes.

### UPnP désactivé

Steam peut ouvrir tout seul des ports sur le routeur via UPnP. Avec WireGuard, ce n'est pas nécessaire. Pour voir l'état actuel :

```bash
/ip upnp print
```

Pour le désactiver, sauf si autre chose en a besoin :

```bash
/ip upnp set enabled=no
```

### CAKE sur l'envoi Internet

Quand tu streames depuis l'extérieur, le goulot est l'**envoi** de ta connexion Internet : le PC y fait partir 12-15 Mbit/s de vidéo. Si un autre appareil envoie en même temps (sauvegarde cloud, photos, mises à jour), la file du routeur se remplit et le stream prend des pics. CAKE, réglé un peu sous le débit réel, empêche ça. Avec `diffserv4`, il donne aussi la priorité aux paquets marqués comme prioritaires, ce que fait l'option d'hôte de Steam « Prioriser le trafic réseau ».

Mets environ 90 % de ton débit d'envoi réel, mesuré sans VPN. Exemple pour 50 Mbit/s mesurés :

```bash
/queue type add name=cake-up kind=cake cake-bandwidth=45M cake-diffserv=diffserv4 cake-nat=yes cake-ack-filter=filter
```

```bash
/queue tree add name=cake-wan-up parent=ether1 queue=cake-up
```

- **Vérifier :** fais un test de bufferbloat (Waveform, par exemple) depuis le LAN pendant un gros envoi, avant et après.
- **Si la file semble sans effet :** la règle FastTrack du pare-feu (`action=fasttrack-connection`) fait sauter certaines étapes de traitement aux paquets. Désactive-la le temps d'un test pour voir si c'est elle.
- **Charge du routeur :** CAKE consomme du CPU, et WireGuard aussi. Pendant un stream :

  ```bash
  /system resource monitor
  ```

  Au-delà de 70-80 % en continu, baisse le débit de CAKE ou retire `cake-ack-filter`.

Le sens de la réception (Internet vers la maison) n'a pas besoin de CAKE pour le stream : la vidéo part de chez toi.

### Réveil du PC à travers le VPN

Le magic packet est un broadcast : depuis le VPN, `wake-host.sh` ne l'envoie pas sur le LAN. Le MikroTik peut l'émettre lui-même, et le Raspberry Pi le relaie ensuite vers la carte Ethernet du PC, comme d'habitude. En SSH sur le routeur, avec la MAC qu'attend le relais :

```bash
/tool wol interface=bridge mac=AA:BB:CC:DD:EE:FF
```

### Si le MikroTik est aussi le point d'accès Wi-Fi

- **5 GHz sur un canal fixe :** plutôt que le choix automatique, qui peut changer de canal en pleine partie.
- **Pas de canal DFS** (canaux 52 à 144) : sur ces canaux, la détection d'un radar oblige la borne à se taire environ une minute, et le stream coupe net. Préfère 36 à 48, ou 149 à 165 si ton pays les autorise.
- **Largeur de canal :** 80 MHz suffit largement pour 15 Mbit/s. Une largeur plus étroite est plus robuste quand le canal est encombré.

## Prérequis manuels (une seule fois)

1. Dans une session de bureau normale : connexion à Steam (Steam Guard) et activation de Remote Play dans les paramètres.
2. Connecter le Deck une première fois et saisir le PIN d'appairage sur l'hôte.
3. **Pare-feu** : si ufw ou firewalld est actif, ouvrir UDP 27031-27036 et TCP 27036-27037.

## Plan de test

| # | Test | Résultat attendu |
|---|---|---|
| 1 | Commande de référence lancée en SSH, session de bureau ouverte | Le Deck voit l'hôte, et l'image, le son et les manettes fonctionnent |
| 2 | Même commande après déconnexion du bureau | Idem. C'est ici qu'on valide uinput et PipeWire sans session |
| 3 | `steamd.service` démarré manuellement, sans session de bureau | Idem, logs propres dans journalctl, `steamd-launch --status` à `running` |
| 4 | Reboot à froid, aucune connexion | Le service est actif et le Deck peut streamer |
| 5 | Connexion au bureau en local | `steamd` passe en `standby` (le service reste actif) et le Steam du bureau démarre normalement |
| 6 | Déconnexion du bureau | `steamd` repasse en `running` dès que le Steam du bureau est fermé |
| 6b | Steam du bureau ouvert, `systemctl --user restart steamd` | Le Steam du bureau n'est pas interrompu, `steamd` reste en `standby` |
| 6c | Partie en Remote Play depuis le Deck, puis connexion au bureau | La partie continue (`busy`) et la popup s'affiche ; « Attendre la fin » : le Steam du bureau s'ouvre tout seul à la fin de la partie |
| 6c' | Idem, bouton « Fermer la partie et ouvrir Steam ici » (ou `steamd-launch --handover`) | La partie et le stream sont fermés, le Steam du bureau s'ouvre en quelques secondes |
| 6d | Jeu lancé au bureau, session verrouillée | La partie continue, `steamd` reste en `standby` |
| 6e | Partie Remote Play en cours | `systemd-inhibit --list` montre le blocage posé par steamd |
| 6f | `IDLE_ACTION=suspend` ou `poweroff`, PC réveillé par WoL sans connexion | Le PC se met en veille ou s'éteint après `IDLE_TIMEOUT` sans partie |
| 7 | PC éteint, raccourci de réveil sur le Deck | Le PC démarre et Remote Play est disponible en moins de 60 s |
| 7b | Idem en VPN WireGuard, avec `WAKE_SSH` configuré | Le magic packet part du relais (journal `wake-host.log`) et le PC démarre |
| 9 | `CLIENT_PROFILES` pour la TV, connexion depuis la TV | `steamd-launch --clients` montre l'IP de la TV ; Steam headless redémarre avec le profil TV ; reconnexion réussie au bon format (statistiques de Steam Link) |
| 9b | Retour au Deck plus de `PROFILE_REVERT_AFTER` après la TV | Profil par défaut déjà en place, connexion sans coupure |
| 9c | `HDR=true` dans le profil TV | Les statistiques montrent un format 10 bits (sinon : le HDR ne passe pas, retirer l'option) |
| 8 | `steamd-doctor` | Rapport lisible, chaque point marqué OK ou KO avec une piste de correction |

## Problèmes connus et pistes

- **Écran noir avec le son qui passe** : problème déjà signalé avec le backend headless de gamescope. Essayer les autres modes de capture Steam, vérifier la version de gamescope, et lancer gamescope avec ses logs détaillés.
- **Manettes inertes** : droits sur `/dev/uinput`, à vérifier avec `steamd-doctor`.
- **`steamd` reste en `standby` après la déconnexion** : un Steam du bureau a survécu à la fermeture de session. `steamd` ne le tue pas volontairement : le fermer avec `steam -shutdown`.
- **Rien ne s'affiche sur le bureau après une partie Remote Play** : vérifier `journalctl --user -u steamd` (« lancement du Steam du bureau »). Si l'environnement graphique n'a pas été importé, lancer Steam à la main et le signaler.
- **La veille automatique ne se déclenche pas** : une session SSH ouverte compte comme une session. Vérifier aussi la règle polkit avec `steamd-doctor`.
- **Pas d'audio** : PipeWire utilisateur pas démarré sans session, à vérifier avec `systemctl --user status pipewire`.
- **Steam démarre mais l'hôte n'apparaît pas sur le Deck** : pare-feu (UDP 27031-27036, TCP 27036-27037) ou Remote Play désactivé.

## État d'avancement

Tout le contenu du périmètre v1 est écrit. Les scripts passent `shellcheck`. Hors machine cible, avec de faux gamescope, Steam et logind, ont été testés : la génération de commande, l'envoi du magic packet et la supervision (lancement, relance après plantage, veille à la connexion, Steam du bureau non interrompu, reprise après sa fermeture, partie Remote Play préservée à la connexion avec passage de main à la fin ou sur demande (popup, `--handover`), blocage de la veille pendant une partie, veille automatique après inactivité, arrêt sans processus restant). **Le plan de test ci-dessus reste à dérouler sur le PC hôte et le Deck.** Points à confirmer en priorité :

- test 2 (uinput et PipeWire sans session) ;
- le bon déclenchement de `steamd-session-hook` par Plasma 6 (`graphical-session-pre.target` puis `graphical-session.target`) ;
- la détection des clients par `ss` (`steamd-probe clients`) et le changement de profil (test 9) ;
- l'arrêt propre via `steam -shutdown` sans affichage ;
- la limite d'images par seconde via MangoHud et les réglages `STREAM_TUNING` dans les jeux lancés par Steam headless (perte d'images et latence d'affichage, à comparer avec `STREAM_TUNING=false`) ;
- ntsync réellement utilisé en jeu (`steamd-doctor` pendant une partie), l'effet d'Anti-Lag Mesa, et le changement de profil d'énergie sans session (règle polkit) ;
- les noms de clés des options Remote Play, à relever avec `steamd-steamcfg diff` ;
- la détection d'une partie via `reaper SteamLaunch AppId=` sur la version de Steam installée ;
- le lancement du Steam du bureau depuis le service (environnement graphique importé par Plasma), l'affichage de la popup et ses boutons dans Plasma ;
- pour `IDLE_ACTION=suspend` : le réveil du PC depuis la veille par le Wake-on-LAN.

### Tests automatiques

`tests/run.sh` vérifie le superviseur et `steamd-steamcfg` avec de faux gamescope, Steam, logind, systemctl, notify-send et powerprofilesctl, sans toucher au vrai Steam ni au système. Il dure environ 2 minutes. Pour ne lancer que certains tests : `tests/run.sh print login busy`.

## Critères de fin pour la v1

- Les tests 1 à 8 passent.
- Une installation sur une CachyOS propre ne demande que : cloner, `./install.sh`, les prérequis manuels, et un reboot.
- Le README couvre l'installation, la configuration, le diagnostic et la désinstallation.
