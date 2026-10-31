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

## Prochaines mesures, par ordre de valeur

1. **L2 (720p)** : configuration à `video=HDMI-A-1:1280x720@60` + `cma=128M`,
   nouvelle charge utile, puis les trois états mesurés (sans Kodi, inactif,
   lecture). C'est la seule mesure qui dira si 1 Gio passe.
2. **L3 (tampons)** : réduire le tampon `inputstream.adaptive`, relancer un flux et
   relever `Rss`/`CmaFree` pendant la lecture. Ne demande aucune reconstruction.
3. **L4 (audio)** : mesurer `pipewire` + `wireplumber` sur une session réelle avant
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
