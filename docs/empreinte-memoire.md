# Empreinte mémoire du kiosque — leviers identifiés

> **Objet** : rendre le kiosque compatible avec des boîtes de **1 Gio de RAM**.
> **Cible de mesure** : Magicsee N5 (GXL, 2 Gio), noyau 7.0.14, HavenOS kiosque
> sur eMMC, système `glxnsrfm…`. Toutes les valeurs ci-dessous sont mesurées sur
> cette boîte le **2026-10-31**, sauf celles marquées « non mesuré ».
> **État** : la boîte 2 Gio n'est pas sous pression (858 Mo disponibles, zram à
> 4 Ko utilisés). Le travail ci-dessous vise la **compatibilité 1 Gio**, pas la
> réparation d'un incident.

## Ce qui est mesuré

| état | RSS `kodi.bin` | `Pss` | `Pss_Anon` | `Pss_File` | CMA utilisée | `MemAvailable` |
|---|---|---|---|---|---|---|
| système **sans Kodi** | — | — | — | — | **10 Mo** | 1 453 Mo |
| Kodi inactif, interface 1080p | 296 Mo | 284 Mo | 181 Mo | 103 Mo | **42 Mo** | 1 240 Mo |
| Kodi en lecture 1080p H.264 (flux d'addon) | **566 Mo** | — | — | — | **137 Mo** | 858 Mo |

Compléments relevés :

| poste | valeur |
|---|---|
| `MemTotal` vu par le noyau | 1 793 Mo (2 048 moins 256 Mo de CMA, réservés **hors** `MemTotal`) |
| `Slab` noyau | 84 Mo — incompressible, mais non négligeable sur 1 Gio |
| `KernelStack` + `PageTables` + `Shmem` | 3 + 5 + 33 Mo |
| somme des RSS hors `kodi.bin` | 262 Mo (double compte les bibliothèques partagées ; le plus gros processus est `wireplumber` à 17 Mo, puis `pipewire` à 14 Mo) |
| zram (swap zstd) | 448 Mo configurés, **4 Ko utilisés** |
| journal systemd | 17,5 Mo, **sur disque** |
| `/tmp` en tmpfs | plafond 897 Mo, **0 utilisé** (Kodi écrit son `temp/` sur disque) |

## Le budget pour 1 Gio

Besoin mesuré à 1080p : `340` (plancher système) `+ 566` (Kodi en lecture)
`= 906 Mo`, et il faut réserver `137 Mo` de CMA par-dessus.

| `cma=` | `MemTotal` | marge après 906 Mo | verdict |
|---|---|---|---|
| `256M` (actuel) | 768 Mo | **−138 Mo** | impossible |
| `160M` | 864 Mo | **−42 Mo** | impossible |
| `128M` | 896 Mo | −10 Mo | impossible, et 128 Mo de CMA < 137 Mo réclamés par la lecture |

**Conclusion mesurée : à 1080p, le kiosque actuel ne rentre pas sur 1 Gio.** Il
manque une centaine de Mo, et le zram ne ferait que swapper des tampons vidéo —
c'est-à-dire saccader. Il faut gagner **~150 Mo** sur l'un des trois postes.

## Les leviers, classés par ce que la mesure justifie

| # | levier | gain | statut | où ça se règle | risque |
|---|---|---|---|---|---|
| L1 | **`cma=` réduit** (256 → 128/160 Mo) | +64 à +128 Mo de `MemTotal` | **mesuré** : 10 Mo sans Kodi, 42 au repos, 137 en lecture 1080p | argument noyau, donc **charge utile** + système | sous-dimensionner casse le 4K HEVC ; 1080p exige ≥ 137 Mo |
| L2 | **mode d'interface 720p** au lieu de 1080p | CMA au repos 42 → ~15 Mo, atlas de textures divisé (aucun chiffre fiable) | **non mesuré** — le test du 31/10 est nul, voir plus bas | `video=HDMI-A-1:…` dans les arguments du noyau, donc **charge utile** | mode inadapté si la TV n'annonce pas 720p ; la mise à l'échelle coûte au compositeur |
| L3 | **tampons du lecteur** (`inputstream.adaptive`, cache de Kodi) | cible des **+270 Mo de RSS et +95 Mo de CMA** de la lecture | non mesuré | réglages Kodi (`kodi-settings`) | tampon trop court = saccades sur les flux irréguliers |
| L4 | **pile audio** : `pipewire` + `wireplumber` → ALSA direct | ~31 Mo | non mesuré | profil kiosque | perd la couche de routage audio du kiosque ; le service de routage HDMI reste nécessaire |
| L5 | **zram** (déjà 448 Mo) | filet, pas un gain | en place, inutilisé ici | profil | aucun ; à augmenter si la pression arrive |
| L6 | **réglages visuels et addons** : vignettes (`extractchapterthumbs`, `extractthumb`, `actorthumbs`, `findremotethumbs`, `generatethumbs`) et douze addons de métadonnées (`themoviedb`, `fanart.tv`, `allmusic`, `musicbrainz`, …) | **nul** | **mesuré nul** : 300 Mo « allégé » contre 301 Mo « restauré » | Kodi | aucun, mais **ne pas compter dessus** |
| L7 | changer de skin | inconnu, probablement faible | non mesuré | `lookandfeel.skin` | aucune garantie : l'atlas d'un autre skin peut être plus gros |

Déjà en place et à ne pas rejouer : fil RSS désactivé (`lookandfeel.enablerssfeeds
= False`), `skinzoom = 0`, journal sur disque, `/tmp` non utilisé.

## Pourquoi le test 720p du 31/10 est nul

Il ne faut pas réutiliser ses chiffres. Trois faits :

1. `Settings.SetSettingValue {"setting":"videoscreen.resolution","value":7}`
   (1280x720p) renvoie `true` et la valeur se lit à chaud… mais Kodi **ne la
   persiste pas** : après `systemctl restart kodi-gbm`, `guisettings.xml` porte
   toujours la valeur par défaut.
2. Le mode est de toute façon imposé au démarrage par
   `video=HDMI-A-1:1920x1080@60` ; le journal affiche `GUI format 1920x1080`
   après **chaque** redémarrage, dans les deux configurations.
3. Le connecteur expose pourtant bien des modes 4K
   (`/sys/class/drm/card0-HDMI-A-1/modes`), donc rien n'empêche un autre mode :
   c'est bien l'argument noyau qui décide.

Conséquence : **L2 ne peut pas être mesuré depuis Kodi**. Il faut reconstruire la
charge utile avec `video=HDMI-A-1:1280x720@60` (voir C8 de
`plan-travaux-restants.md`), puis refaire les trois mesures.

## Pièges de mesure (payés une fois)

- **Lire `Pss` trop tôt fausse tout** : 18 s après un démarrage, `kodi.bin` mesure
  233 Mo ; à chaud, 296 Mo. Attendre **60 s** avant toute lecture, et comparer des
  états de maturité équivalente.
- **`MainPID` n'est pas `kodi.bin`** : c'est le wrapper `.kodi-wrapped`. Mesurer le
  CPU sur ce PID donne 0 %, et la mémoire sur le mauvais processus.
- **Le bruit est d'environ ±20 Mo** : l'écart entre deux états identiques mesurés à
  des âges différents atteint 17 Mo. Tout effet inférieur à ~20 Mo est invisible
  ici et ne doit pas être annoncé comme un gain.
- **`CmaTotal` est hors `MemTotal`** : réduire la CMA rend de la mémoire au
  système, mais ne se lit pas dans `free`.
- **`RSS` cumulé sur tous les processus surestime** (bibliothèques partagées
  comptées plusieurs fois) : préférer `smaps_rollup` par processus.

## Mesure L2 — 720p + `cma=128M`, faite le 2026-10-31

Système `kx4a88fm…` (branche `mesure/l2-prod`, construite sur la production du
jour), `cma=128M`, `video=HDMI-A-1:1280x720@60`, sans carte SD. `MemTotal`
1 835 796 Ko. Relevés produits par `scripts/mesure-memoire.sh`, source déclarée
avec `--source`.

| état | source | `CmaFree` | CMA utilisée | `Pss` kodi.bin | mémoire occupée |
|---|---|---|---|---|---|
| sans Kodi | — | 125 012 | 5,9 Mo | — | 331 452 Ko |
| inactif | — | 110 736 | 19,9 Mo | 307 240 Ko | 561 772 Ko |
| lecture | replay 720p | 46 388 | 82,7 Mo | 372 087 Ko | 700 996 Ko |
| lecture | mire 1080p | 27 236 | **101,4 Mo** | 392 440 Ko | **825 456 Ko** |

Pour comparaison, la référence 1080p du même protocole : CMA 137 Mo en lecture,
`Pss` 327 120 Ko au repos, 858 Mo occupés en lecture.

**Effet propre du mode d'affichage, mesuré sans décodeur actif** (les deux
colonnes sont comparables, aucune source en jeu) : CMA au repos
**42,0 → 19,9 MiB** (−22,1), `Pss` **319,6 → 300,0 MiB** (−19,5). Soit
**41,7 MiB** gagnés.

### Verdict sur la cible 1 Gio (D3)

Sur cette carte, 261 356 Ko échappent à `MemTotal` : 131 072 de CMA plus 130 284
de noyau et réservations. Sur une carte de 1 Gio avec `cma=128M`, `MemTotal`
vaudrait donc ≈ **787 220 Ko (768 Mio)**.

| scénario sur 1 Gio | occupé | marge |
|---|---|---|
| lecture d'une source **720p** | 684,6 MiB | **+84,2 MiB** — passe |
| lecture d'une source **1080p** | 806,1 MiB | **−37,3 MiB** — ne passe pas |

Conclusion honnête : **1 Gio tient si le contenu est en 720p, pas s'il est en
1080p**, à moins de récupérer ~37 MiB dans le pied de Kodi. La cible « 1 Gio »
n'est donc pas tranchée par L2 seule : elle dépend de la définition des sources,
ce que le document initial ne distinguait pas.

Deux pièges payés pendant cette mesure :

- **La résolution décodée ne se lit pas sur `/dev/video0`.** Sur ce pilote
  stateless le format reste figé au premier `S_FMT` : il annonçait `1280/720`
  pendant le décodage d'une mire 1920x1080. C'est l'écart de CMA (82,7 → 101,4 Mo)
  qui prouve le 1080p, pas le sysfs. D'où `--source`, déclaré par l'opérateur.
- **Les replays france.tv sont en 720p**, quelle que soit l'émission. Pour une
  mesure 1080p il faut une mire locale (voir plus bas) ou une chaîne en direct HD.

La mire de référence est un H.264 High@4.0 1920x1080 25 i/s de 30 s, générée par
`ffmpeg -f lavfi -i testsrc2=size=1920x1080:rate=25:duration=30 -c:v libx264
-profile:v high -pix_fmt yuv420p -b:v 4M -g 50 -an`, puis posée dans le store de
la carte (`nix store add-file` + `nix copy`) et lancée par `Player.Open`. Même
source pour toutes les mesures futures, indépendante de la playlist.

### Pourquoi L3 ne peut pas combler les 37,3 MiB

Le coût de la lecture se répartit en deux postes : ~90 MiB d'anonyme en plus dans
Kodi, et ~80 MiB de CMA — mais **la CMA est hors `MemTotal`**, elle ne pèse donc
pas sur le budget 1 Gio. Tout le déficit est dans l'anonyme de Kodi.

Les leviers « tampon » sont sans effet mesurable ici : `filecache.memorysize`
passé de 128 à 16 ne change rien sur un fichier local (**755,1 → 752,8 MiB**,
écart dans le bruit). La mémoire est ailleurs.

Conclusion : **L3 ne tranche pas D3, il l'entérine** — sur ce stack, 1 Gio tient
avec des sources 720p (+84,2 MiB de marge) et ne tient pas avec des sources
1080p (−37,3 MiB), et il n'existe pas de réglage qui comble l'écart. Les sorties
réalistes sont : n'accepter que du 720p sur un SKU 1 Gio, changer de lecteur, ou
prendre une carte à plus de RAM.

### Attribution du pied, mesurée le 31/10 à l'état inactif (1080p, production)

| poste | mesure |
|---|---|
| `kodi.bin` | **295,3 MiB** de `Pss` |
| tous les services système réunis | **~100 MiB** de `Pss` (le plus gros : wireplumber 9,4, pipewire 6,9, systemd 6,7, wpa_supplicant 6,1, resolved 6,1, udevd 5,7) |
| total `Pss` tous processus | **395 MiB** |
| `Slab` | 69,3 MiB dont 44,2 non récupérables |
| `Shmem` | 31,2 MiB |
| occupé (`MemTotal − MemAvailable`) | 587 MiB |

Deux conséquences pour D3 : le pied système n'est **pas** le gisement (100 MiB de
services, dont ~29 MiB d'audio — la cible L4), et les 37,3 MiB manquants sont
dans le **pied de Kodi lui-même**. Le tampon `inputstream.adaptive` tourne aux
valeurs par défaut (~15 Mo) : il ne peut pas rendre 37 MiB à lui seul. Le levier
plausible est ailleurs dans Kodi — addons chargés, textures du skin — et se
mesure par ablation.

**Correction** : la première publication de ce document annonçait « −57 Mo ». Le
calcul avait mélangé Mo décimaux et Mio. Les valeurs ci-dessus sont en Mio,
recalculées depuis les KiB de `/proc/meminfo` ; le déficit réel est de
**37,3 MiB**.

### Où sont réellement les 130 MiB : les addons activés

Bisection mesurée le 31/10, un redémarrage par configuration, 60 s de chauffe.
Reproductibilité contrôlée : deux redémarrages consécutifs de la même
configuration donnent **300,4** et **299,9 MiB** — l'écart entre configurations
est donc réel, pas du bruit.

| addons activés | `Pss` kodi.bin | dont anonyme |
|---|---|---|
| 51 (production) | **300 MiB** | 199 MiB |
| 43 (les 8 greffons coupés) | **160 MiB** | 62 MiB |
| 44 (+ `service.iptv.manager` seul) | 170 MiB | 71 MiB |
| 45 (+ `plugin.video.vstream` seul) | 198 MiB | 98 MiB |

Les **sept greffons VOD** (`vstream`, `xtream`, `orange.tv`, `pluto.tv`,
`rakuten.tv`, `samsung.tvplus`, `sendtokodi`) pèsent **~130 MiB**, en mémoire
**anonyme** — des textures d'illustration chargées, pas du code. Le gestionnaire
IPTV en coûte ~10, `vstream` seul ~29.

Conséquence pour D3 : le levier n'est ni les services système (95 MiB au total,
dont 19 sockets à coût nul — `nix-daemon` en est, 0 MiB ; couper SSH, DNS et NTP
ne rend qu'une vingtaine de MiB), ni une recompilation de Kodi (voir ci-dessous),
mais **la liste des addons activés**. Couper les greffons VOD inutilisés rend
jusqu'à 130 MiB, soit largement les 37,3 MiB manquants.

### Ce qu'un Kodi recompilé ne rendrait pas

Options réellement passées au build (`nix derivation show`) :
`ENABLE_OPTICAL=ON` (libdvdnav/libdvdread/libdvdcss) et `ENABLE_VDPAU=ON`
(NVIDIA). Aucune de ces bibliothèques n'apparaît dans le `Pss_File` de Kodi :
elles ne sont **jamais mappées** quand la fonction n'est pas utilisée. Les
désactiver au build ne rend **aucune RAM** — seulement de la taille d'image.

Le code mappé, lui, est : `kodi.bin` 26 MiB, `libLLVM` 29,2 et `libgallium` 11,4
(compilateur et pilote **lima/mesa**, indispensables au rendu Mali450),
`libpython` 6, `libavcodec` 3,1. Élaguer les options de Kodi peut retirer
quelques MiB de code, pas 37, et casserait les fonctions qui font la boîte.

## Chantier suivant : empreinte des addons (à ouvrir, mesuré le 31/10)

**Acquis** : sept greffons VOD coûtent ~130 MiB d'anonyme à l'activation, dont
`vstream` 29 et `service.iptv.manager` 10 ; le reste se répartit sur
`xtream`, `orange.tv`, `pluto.tv`, `rakuten.tv`, `samsung.tvplus`,
`sendtokodi`. Rien de tout cela n'est du code mappé : c'est de la mémoire
allouée, très probablement des textures d'illustration (les `fanart.jpg` des
paquets pèsent 0,5–0,8 Mo, soit ~8 Mo en RGBA une fois décodés).

**Qui a la main** : les cinq greffons maison (`xtream`, `orange.tv`, `pluto.tv`,
`rakuten.tv`, `samsung.tvplus`) et `script.module.tv_common` sont dans le
monorepo privé `tv-addons` — code et ressources à nous. `vstream`,
`sendtokodi` et `service.iptv.manager` sont packagés par HavenOS (`pkgs/`) mais
leur code vient de l'amont : on les corrige par patch ou par réglage, pas par
réécriture. `pvr.iptvsimple` est un paquet nixpkgs.

**Hypothèses, dans l'ordre de coût** :
1. les fanarts sont décodés en textures à l'activation de l'addon → réduire ou
   supprimer les `resources/media/*.jpg` des cinq addons maison, puis remesurer ;
2. un module Python est importé au démarrage → vérifier avec `kodi.log` en debug
   (`CAddon` / imports) sur un seul greffon activé ;
3. le skin précharge les vignettes des addons → tester avec un skin sans
   vignettes ou un menu d'accueil réduit.

**Protocole** (déjà éprouvé) : un redémarrage par configuration, 60 s de chauffe,
`Pss`/`Pss_Anon` de `kodi.bin`, et **deux runs identiques** pour la
reproductibilité (mesuré : 300,4 et 299,9 MiB). Activer un greffon à la fois :
c'est la seule façon d'attribuer, le lot ne le permet pas.

**Critère de réussite** : 1 Gio défendable en 1080p, c'est-à-dire `MemTotal`
768,8 MiB avec **plus de 100 MiB de marge** en lecture. La liste d'addons
minimale est à arbitrer avec l'usage réel ; elle va dans le sens d'un système
déterministe (moins d'état, moins de réseau, démarrage plus court).

**À caractériser avant de promettre quoi que ce soit** : l'anonyme de Kodi passe
de 59 à 156 MiB avec l'usage (relevés 755 MiB à froid contre 806 MiB après une
heure). Plateau ou dérive, la réponse change le verdict 1 Gio — échantillonner
`Pss_Anon` sur 2 h avant de conclure.

## Prochaines mesures, par ordre de valeur

1. **L3 (tampons)** : réduire le tampon `inputstream.adaptive`, relancer la mire
   1080p et relever `CmaFree`/`Pss` pendant la lecture. C'est la seule mesure qui
   peut combler les ~57 Mo manquants pour tenir 1 Gio avec des sources 1080p ; elle
   ne demande aucune reconstruction. Le reste de L2 est fait (voir ci-dessus).
2. **L4 (audio)** : mesurer `pipewire` + `wireplumber` sur une session réelle avant
   de décider ; 31 Mo ne suffisent pas à faire passer le budget, mais ils comptent
   si L2 n'en rend pas assez.

Les trois états se rejouent avec `scripts/mesure-memoire.sh` (poste → carte en
SSH), qui encode les pièges ci-dessus : chauffe de 60 s avant l'état inactif,
`Pss` lu sur `kodi.bin` et jamais sur `MainPID`, `CmaTotal` lu dans
`/proc/meminfo` et non déduit de `MemTotal`, et réparation de la pile audio
après l'arrêt du kiosque (le trou de plus de 10 s de l'item 49 est inévitable
dans l'état « sans Kodi »).

```sh
scripts/mesure-memoire.sh --host root@<ip> --etat tous --sortie memoire.csv
```
