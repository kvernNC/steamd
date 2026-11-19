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
- Gestion du conflit avec une session de bureau : un seul Steam à la fois. Par défaut, **le Steam de la session graphique n'est jamais coupé** : quand quelqu'un utilise le PC, `steamd` ferme son Steam headless et passe en veille, puis reprend après la déconnexion, une fois le Steam du bureau fermé. Ce comportement est configurable.
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
├── bin/
│   ├── steamd-launch           # wrapper : lit la conf, lance gamescope et Steam
│   ├── steamd-doctor           # diagnostic
│   └── steamd-session-hook     # arrêt et reprise selon la session locale
├── deck/
│   └── wake-host.sh            # envoi du magic packet depuis le Deck
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
| Scripts | `steamd-launch`, `steamd-doctor` et `steamd-session-hook` dans `~/.local/bin` |
| Unités | `steamd.service` et `steamd-session-hook.service` dans `~/.config/systemd/user`, activées |
| Configuration | `~/.config/steamd/steamd.conf` copié depuis l'exemple, **seulement s'il n'existe pas** |
| udev | `/etc/udev/rules.d/60-steamd-uinput.rules` (groupe `input` par défaut, `--group NOM` pour changer) |
| Module | `/etc/modules-load.d/steamd-uinput.conf` pour charger `uinput` au boot |
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
STEAM_CAPTURE=pipewire-dmabuf   # pipewire-dmabuf | pipewire | none
STEAM_UI_ARG="-tenfoot"         # ou -gamepadui
GAMESCOPE_EXTRA_ARGS=""
STEAM_EXTRA_ARGS=""
DESKTOP_SESSION_POLICY=yield    # yield | takeover
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

## Fonctionnement

`steamd.service` est un service **permanent** : activé au boot, il ne s'arrête jamais de lui-même (`Restart=always`). Il exécute `steamd-launch`, un superviseur qui réévalue la situation toutes les `POLL_INTERVAL` secondes :

| Situation | État | Action |
|---|---|---|
| Aucune session graphique locale, aucun autre Steam | `running` | Steam headless lancé dans gamescope (et relancé s'il plante) |
| Session graphique locale ouverte, politique `yield` (défaut) | `standby` | Steam headless fermé proprement ; le Steam du bureau a la priorité |
| Un Steam lancé hors de steamd tourne encore (bureau, terminal…) | `standby` | **jamais tué** : steamd attend qu'il se ferme, puis reprend la main |
| Fin inattendue de gamescope ou de Steam | `backoff` | relance après `RESTART_DELAY` × nombre d'échecs rapprochés (300 s max) |

- **Politique `takeover`** : Steam headless reste actif même pendant une session de bureau. Le Steam du bureau s'ouvre alors *dans* l'instance headless, invisible à l'écran. C'est utile seulement si le PC sert surtout de serveur.
- **`steamd-session-hook.service`** est rattaché à `graphical-session.target`, que Plasma démarre à la connexion. À la connexion, il s'exécute *avant* le bureau (`Type=oneshot`, donc bloquant) : il réveille le superviseur (SIGUSR1) et attend qu'il soit en veille. Le Steam du bureau démarre ensuite normalement. À la déconnexion, il réveille le superviseur pour une reprise immédiate. Une connexion SSH n'ouvre pas de session graphique et n'a aucun effet.
- **Arrêt de Steam headless** : `steam -shutdown`, puis `STOP_TIMEOUT` secondes de délai, puis SIGTERM et enfin SIGKILL sur le groupe de processus gamescope. Un dernier balayage du cgroup du service garantit qu'aucun reste ne survit à la mise en veille.
- **Environnement** : `DISPLAY` et `WAYLAND_DISPLAY` hérités d'une ancienne session Plasma sont retirés avant de lancer gamescope.
- **Code de sortie `2`** : configuration invalide. C'est le seul cas où systemd ne relance pas le service.

L'état courant (`running`, `standby`, `backoff`, `stopped`) et sa raison s'affichent avec :

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
| 7 | PC éteint, raccourci de réveil sur le Deck | Le PC démarre et Remote Play est disponible en moins de 60 s |
| 8 | `steamd-doctor` | Rapport lisible, chaque point marqué OK ou KO avec une piste de correction |

## Problèmes connus et pistes

- **Écran noir avec le son qui passe** : problème déjà signalé avec le backend headless de gamescope. Essayer les autres modes de capture Steam, vérifier la version de gamescope, et lancer gamescope avec ses logs détaillés.
- **Manettes inertes** : droits sur `/dev/uinput`, à vérifier avec `steamd-doctor`.
- **`steamd` reste en `standby` après la déconnexion** : un Steam du bureau a survécu à la fermeture de session. `steamd` ne le tue pas volontairement : le fermer avec `steam -shutdown`.
- **Pas d'audio** : PipeWire utilisateur pas démarré sans session, à vérifier avec `systemctl --user status pipewire`.
- **Steam démarre mais l'hôte n'apparaît pas sur le Deck** : pare-feu (UDP 27031-27036, TCP 27036-27037) ou Remote Play désactivé.

## État d'avancement

Tout le contenu du périmètre v1 est écrit. Les scripts passent `shellcheck`. Hors machine cible, avec de faux gamescope, Steam et logind, ont été testés : la génération de commande, l'envoi du magic packet et la supervision (lancement, relance après plantage, veille à la connexion, Steam du bureau non interrompu, reprise après sa fermeture, arrêt sans processus restant). **Le plan de test ci-dessus reste à dérouler sur le PC hôte et le Deck.** Points à confirmer en priorité :

- test 2 (uinput et PipeWire sans session) ;
- le bon déclenchement de `steamd-session-hook` par Plasma 6 (`graphical-session-pre.target` puis `graphical-session.target`) ;
- l'arrêt propre via `steam -shutdown` sans affichage.

## Critères de fin pour la v1

- Les tests 1 à 8 passent.
- Une installation sur une CachyOS propre ne demande que : cloner, `./install.sh`, les prérequis manuels, et un reboot.
- Le README couvre l'installation, la configuration, le diagnostic et la désinstallation.
