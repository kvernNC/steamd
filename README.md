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

- Service systemd **utilisateur** `steamd.service` qui lance `gamescope --backend headless` avec Steam en Big Picture.
- Activation du *linger* pour que le service démarre au boot sans session.
- Dépendances PipeWire et WirePlumber en services utilisateur (vidéo et audio sans session graphique).
- Règle udev donnant l'accès à `/dev/uinput` sans session active (manettes virtuelles du Remote Play), par exemple via le groupe `input`.
- Client Steam distinct de celui du bureau : même utilisateur, mais HOME dédié (`STEAMD_HOME`). Les deux Steam tournent en parallèle, et seule la bibliothèque de jeux est partagée. Remote Play n'est activé que dans le client steamd.
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
│   └── steamd.service          # unité utilisateur
├── udev/
│   └── 60-steamd-uinput.rules
├── bin/
│   ├── steamd-launch           # wrapper : lit la conf, lance gamescope et Steam
│   ├── steamd-doctor           # diagnostic
│   └── steamd-setup            # partie utilisateur de l'installation
├── src/
│   └── steamd-vaapi.c          # LD_PRELOAD : CBR + tampon d'une image pour l'encodeur VA-API
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

## Configuration (`~/.config/steamd/steamd.conf`)

```ini
WIDTH=1280
HEIGHT=800
REFRESH=60
STEAM_CAPTURE=pipewire-dmabuf   # pipewire-dmabuf | pipewire | none
GAMESCOPE_EXTRA_ARGS=""
STEAM_EXTRA_ARGS=""
ENCODER=""                      # hardware | software | vide
VAAPI_STRICT_RC=false
#STEAMD_HOME="$HOME/.local/share/steamd-home"
```

## Exigences techniques

1. **Sans session** : le service doit fonctionner après un boot à froid, sans connexion à SDDM. On le vérifie en redémarrant puis en se connectant uniquement en SSH.
2. **Linger** : `loginctl enable-linger $USER`, géré par `install.sh`.
3. **PipeWire** : `pipewire.socket`, `pipewire-pulse.socket` et `wireplumber.service` activés en utilisateur. `steamd.service` doit être ordonné après eux.
4. **GPU** : vérifier l'accès à `/dev/dri/renderD*` sans session. Normalement ouvert, mais le diagnostic doit le contrôler.
5. **Entrées** : sans session, `uaccess` ne s'applique pas. Il faut une règle udev qui ouvre `/dev/uinput` à un groupe dont l'utilisateur fait partie. `install.sh` ajoute l'utilisateur au groupe et recharge udev.
6. **Deux clients séparés** : Steam n'autorise qu'une instance par HOME. steamd lance donc le sien avec `HOME=$STEAMD_HOME` et ne touche jamais au `~/.steam` du bureau. Comme l'UID est le même, la bibliothèque partagée et les préfixes Proton n'ont aucun problème de droits.
7. **Robustesse** : `Restart=on-failure` avec un délai. Les logs sont lisibles via `journalctl --user -u steamd`.
8. **Idempotence** : `install.sh` et `uninstall.sh` peuvent être relancés sans effet de bord. `uninstall.sh` retire tout ce que `install.sh` a ajouté (unité, règle udev, groupe en option, linger en option).

## Côté Steam Deck

- `deck/wake-host.sh` envoie un magic packet en broadcast sur le LAN (MAC et broadcast configurables en tête de script). Sans dépendance exotique : Python stdlib ou `wakeonlan` s'il est présent.
- L'ajouter en jeu non-Steam depuis le mode bureau, pour pouvoir le lancer depuis le mode jeu.
- Le Pi se charge de la traduction vers la carte Ethernet du PC.

## Prérequis manuels (une seule fois)

Dans la session de bureau, le Steam du bureau peut rester ouvert :

1. `systemctl --user stop steamd`, puis `steamd-launch --setup` : le client steamd s'ouvre en fenêtre.
2. Le Steam du bureau doit être fermé pendant cette configuration, sinon il garde les ports de Remote Play. Se connecter (Steam Guard) et activer Remote Play.
3. Paramètres > Stockage : ajouter la bibliothèque du bureau (`~/.local/share/Steam`, ou le disque de jeux). Steam reconnaît les jeux déjà installés.
4. Paramètres > Téléchargements : limiter les mises à jour à une plage horaire où le PC est éteint. C'est le Steam du bureau qui fait les mises à jour, pour éviter que deux clients mettent à jour le même jeu en même temps.
5. Paramètres > Pré-mise en cache des shaders : désactiver la pré-mise en cache et le traitement Vulkan en arrière-plan. Le bureau construit déjà les caches dans `steamapps/shadercache` de la bibliothèque partagée. Sans ce réglage, ils sont retéléchargés en double, et un traitement en cours bloque le lancement des jeux depuis le Deck.
6. Appairer le Deck dans cette fenêtre. En headless, le PIN ne peut pas être saisi, car aucun écran n'affiche la demande.
7. Quitter complètement ce client, puis `systemctl --user start steamd`.

Côté bureau : désactiver Remote Play (Paramètres > Remote Play) et les transferts de jeux sur le réseau local (Paramètres > Téléchargements), puis relancer Steam. Les deux clients visent les mêmes ports (UDP 27036, TCP 27036-27037), et le premier démarré les garde. Dans ce cas, le Deck ne voit pas steamd. `steamd-doctor` vérifie à qui appartiennent ces ports.

## Plan de test

| # | Test | Résultat attendu |
|---|---|---|
| 1 | Commande de référence lancée en SSH, session de bureau ouverte | Le Deck voit l'hôte, et l'image, le son et les manettes fonctionnent |
| 2 | Même commande après déconnexion du bureau | Idem. C'est ici qu'on valide uinput et PipeWire sans session |
| 3 | `steamd.service` démarré manuellement | Idem, logs propres dans journalctl |
| 4 | Reboot à froid, aucune connexion | Le service est actif et le Deck peut streamer |
| 5 | Session de bureau ouverte, Steam du bureau lancé | Les deux Steam tournent. Le Deck streame depuis steamd sans gêner le bureau |
| 6 | Jeu lancé depuis le Deck pendant que le bureau est utilisé | Le bureau n'est pas modifié (ni fenêtre ni changement de résolution) |
| 7 | PC éteint, raccourci de réveil sur le Deck | Le PC démarre et Remote Play est disponible en moins de 60 s |
| 8 | `steamd-doctor` | Rapport lisible, chaque point marqué OK ou KO avec une piste de correction |

## Problèmes connus et pistes

- **Écran noir avec le son qui passe** : problème déjà signalé avec le backend headless de gamescope. Essayer les autres modes de capture Steam, vérifier la version de gamescope, et lancer gamescope avec ses logs détaillés.
- **Manettes inertes** : droits sur `/dev/uinput`, à vérifier avec `steamd-doctor`.
- **Pas d'audio** : PipeWire utilisateur pas démarré sans session, à vérifier avec `systemctl --user status pipewire`.
- **Steam démarre mais l'hôte n'apparaît pas sur le Deck** : le Steam du bureau garde les ports (voir les prérequis), un pare-feu bloque (UDP 27031-27036, TCP 27036-27037), ou Remote Play est désactivé dans le client steamd.
- **Le Deck demande un appairage** : le faire avec `steamd-launch --setup`, service arrêté.
- **Pertes de paquets quand l'image bouge, avec un GPU AMD** : l'encodeur VA-API dépasse ponctuellement le débit visé, et ces pointes saturent le Wi-Fi. Monter le débit aggrave les pertes. Autre solution : garder l'encodeur matériel avec `ENCODER=hardware` et `VAAPI_STRICT_RC=true`. La bibliothèque `libsteamd-vaapi.so` (`src/steamd-vaapi.c`), chargée par `LD_PRELOAD`, impose alors à Steam le réglage de Sunshine avec `vaapi_strict_rc_buffer` : du CBR avec un tampon HRD d'une seule image (débit divisé par la fréquence). Le pilote radeonsi ne propose pas ICQ, et même réglé sur `vaapi_rc = icq`, Sunshine encode en CBR. On vérifie le chargement avec `steamd-doctor`, et les corrections apparaissent dans `journalctl --user -u steamd | grep steamd-vaapi`.
Pour passer en x264, mettre `ENCODER=software` dans `steamd.conf`. `steamd-launch` modifie alors `EnableHardwareEncoding` dans `localconfig.vdf` avant chaque démarrage. On peut aussi décocher « Activer l'encodage matériel » dans Paramètres > Remote Play > Options avancées de l'hôte du client steamd. Sur un Deck, on a mesuré 0 % de pertes et 9,8 ms de latence d'affichage en 1280×800.
- **Lag sans pertes ni ping élevé** : le délai vient d'avant la capture. Mettre `REFRESH` à la fréquence du client (90 pour un Deck OLED, 60 pour un Deck LCD ou une TV), couper la synchro verticale dans le jeu et utiliser son limiteur d'images.

## Critères de fin pour la v1

- Les tests 1 à 8 passent.
- Une installation sur une CachyOS propre ne demande que : cloner, `./install.sh`, les prérequis manuels, et un reboot.
- Le README couvre l'installation, la configuration, le diagnostic et la désinstallation.

## Utilisation

### Installation par paquet (recommandée)

```bash
git clone <repo> && cd steamd/packaging/arch
makepkg -si       # installe dans /usr (scripts, unités, règle udev, module uinput)
steamd-setup      # en utilisateur : configuration, groupe input, linger, services
sudo reboot
```

### Installation sans paquet

```bash
git clone <repo> && cd steamd
./install.sh      # sudo demandé pour udev, le groupe input et le linger
sudo reboot
```

`install.sh` copie les scripts dans `~/.local/bin` et l'unité `steamd.service` dans `~/.config/systemd/user`, puis lance `steamd-setup`. Dans les deux cas, `steamd-setup` crée `~/.config/steamd/steamd.conf` s'il n'existe pas encore.

### Configuration

Modifier `~/.config/steamd/steamd.conf`, puis lancer `systemctl --user restart steamd`. En cas d'écran noir, passer `STEAM_CAPTURE` à `pipewire`, puis à `none`.

### Cohabitation avec le Steam du bureau

steamd et le Steam du bureau sont deux clients indépendants. On peut ouvrir ou fermer sa session, et lancer ou quitter le Steam du bureau, sans effet sur steamd.

Le compte Steam est le même : un seul jeu peut tourner à la fois. Si un jeu est lancé sur le bureau, le Deck ne peut pas en lancer un autre (« en cours d'utilisation sur un autre ordinateur »).

### Diagnostic

```bash
steamd-doctor
journalctl --user -u steamd -f
```

### Désinstallation

```bash
# paquet
steamd-setup --undo [--remove-group] [--disable-linger] [--purge]
sudo pacman -R steamd

# sans paquet
./uninstall.sh [--remove-group] [--disable-linger] [--purge]
```

### Steam Deck

Renseigner `MAC` (et au besoin `BROADCAST`) en tête de `deck/wake-host.sh`. Copier le script sur le Deck, le rendre exécutable, puis l'ajouter comme jeu non-Steam depuis le mode bureau.

## Licence

MIT, voir [LICENSE](LICENSE).
