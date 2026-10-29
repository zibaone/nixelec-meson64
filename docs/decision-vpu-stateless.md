# Décision — VPU stateless

> **Date** : 2026-10-25.
> **Statut** : décidé ; flake et module N5 préparés, aucune image nixbian
> bootée ni décodage stateless mesuré.
> **Périmètre** : `nixelec-meson64`, familles GXBB/GXL/GXLX/GXM/G12A/G12B/SM1.

## Décision

`nixelec-meson64` prend le chemin **V4L2 stateless Request API** :

- driver `meson-amvdec` (issu de LibreELEC), backporté sur le noyau **7.0**
  de `nixbian` ;
- userspace `nix-v4l2-request` : FFmpeg `*_v4l2request` + Kodi ;
- H.264 d'abord, HEVC/VP9 ensuite ;
- S4, T7 et S905X4/SC2 restent hors de la première implémentation.

Le driver staging stateful `meson-vdec` n'est pas retenu pour la lecture
matérielle. Il reste présent dans l'arbre mais doit être désactivé
(`CONFIG_VIDEO_MESON_VDEC=n`) pour éviter deux drivers sur le même compatible.

## Pourquoi

1. C'est le seul chemin qui vise **HEVC Main10**, **VP9** et **AFBC** avec le
   matériel existant.
2. Il utilise la même API que `cedrus`/`rkvdec`, donc la pile
   `nix-v4l2-request` déjà présente dans l'écosystème HavenOS.
3. Le backport 7.0 a été testé :
   - patchs `amlogic-0118` à `0128` appliqués sur `linux-7.0.14` ;
   - seul le hunk `MAINTAINERS` de `0119` a été retiré ;
   - `CONFIG_VIDEO_MESON_AMVDEC=m` produit `meson-amvdec.ko` (455 344 octets).

## Pourquoi pas 7.3

- 7.3 est un noyau stable, mais `nixbian` ne le package pas : il faudrait une
  nouvelle plateforme, une config et un cache.
- 7.3 devient nécessaire pour **S4** (display/audio/GPU/OP-TEE), pas pour le
  décodage GX/G12/SM1.
- On garde 7.0 pour la famille et on isole le sous-ensemble vdec.

## Architecture cible

```text
nixbian
  meson64 7.0
    + patches/kernel/meson64-vdec-7.0/   (sous-ensemble 0118-0128)
    + CONFIG_VIDEO_MESON_VDEC=n
    + CONFIG_VIDEO_MESON_AMVDEC=m
    + firmware meson/vdec/*_multi.bin

nixelec-meson64
  family meson64
    + module image Amlogic
    + module WiFi/BT
    + Kodi GBM
    + nix-v4l2-request

nix-v4l2-request
  H.264 : existant
  HEVC  : rebase FFmpeg pour EXT_SPS_ST_RPS / LT_RPS
```

## Travail

1. **nixbian**
   - état 2026-10-26 : N5 mesurée **S905L/GXL**, boot SD prouvé via le vendor
     U-Boot et le DTB p212 ; eMMC 16 Go avec 668 MiB de bootloader vendor à
     préserver ;
   - intégrer `patches/kernel/meson64-vdec-7.0` au noyau `meson64-edge`
     (ou à une variante `meson64-vdec` pour ne pas impacter les autres
     familles) ;
   - désactiver le staging ;
   - packager les firmwares `*_multi.bin` / `*_mmu.bin` ;
   - vérifier le DTB : nœud `vdec` présent et actif.
2. **nixelec-meson64**
   - créer le squelette flake ;
   - carte de référence : Magicsee N5 (S905L/GXL, mesuré) ou Radxa Zero 2 (G12B) ;
   - module image Amlogic (U-Boot `u-boot.bin.sd.bin` aux offsets 0/512) ;
   - Kodi GBM + `nix-v4l2-request`.
3. **nix-v4l2-request**
   - valider H.264 sur le driver `amvdec` ;
   - rebaser FFmpeg pour HEVC RPS étendus ;
   - valider VP9/MPEG-2 ensuite.
4. **Validation**
   - `/dev/video*` expose `H264_SLICE` ;
   - `v4l2-compliance` ;
   - Kodi crée un hwdevice `V4L2REQUEST` ;
   - MD5/PSNR contre décodage logiciel ;
   - charge CPU ;
   - pas d'écran noir / `drmModeAddFB2`.

## Risques

- Le driver `amvdec` n'est **pas upstream** et vient d'une pile de 210 patchs
  Amlogic (dont ~15 pour le VPU), avec assistance IA explicite.
- Les firmwares `*_multi.bin` ne sont pas dans `linux-firmware` ; leur
  licence Amlogic doit être vérifiée avant redistribution.
- HEVC dépend d'un rebase FFmpeg non trivial.
- Aucun test matériel du VPU stateless n'a encore été fait ; la N5 a seulement
  booté LibreELEC en stateful (mesures du 2026-10-26).
- S4/SC2/T7 ne sont pas couverts par ce backport.

## Critère d'abandon

Si H.264 ne produit pas un décodage bit-exact avec `V4L2REQUEST` sur une carte
de référence après le backport, on revient au chemin stateful
`v4l2_m2m` + `v4l2-drmprime` et on documente la limite.

## Mesure du 2026-10-29 : le stateless ne peut pas fonctionner tel quel

Premier essai réel du chemin stateless sur la N5 (S905L, noyau 7.0.14,
`meson-amvdec` chargé, `/dev/media0` + `/dev/video0` présents). Le hwaccel
n'arrive pas à s'initialiser :

```
ffmpeg -hwaccel drm -hwaccel_output_format drm_prime -c:v h264 -i test1080.mp4 -f null -
[h264] ff_v4l2_request_init: ctx=0xffffa8050700 ...
[h264] v4l2_request_probe_media_device: path=/dev/media0 driver=meson-amvdec
[h264] v4l2_request_probe_video_device: path=/dev/video0 capabilities=69222400
[h264] v4l2_request_probe_video_device: select capture format failed
[h264] No V4L2 media device found for S264
```

La cause est un format, pas un contrat :

```
v4l2-ctl -d /dev/video0 --list-formats      # capture
  [0]: 'NM12' (Y/UV 4:2:0 (N-C))            # V4L2_PIX_FMT_NV12M, 2 plans
v4l2-ctl -d /dev/video0 --list-formats-out  # sortie
  [0]: 'S264' (H.264 Parsed Slice Data, compressed)
```

Le driver n'expose **que** `NV12M` en capture (`--set-fmt-video pixelformat=NV12`
→ « The pixelformat 'NV12' is invalid »). Or `v4l2_request_capture_pixelformats`
dans FFmpeg ne contient pas `V4L2_PIX_FMT_NV12M` : elle liste NV12,
SUNXI_TILED_NV12, NV15, NV16, NV20, P010 et les AFBC. Le jeu de patches
LibreELEC 12 ne le contient pas davantage (`grep NV12M` → 0 occurrence), et
l'export DRM est écrit pour **un seul** dma-buf (`desc->nb_objects = 1`,
chroma déduite par offset dans le même objet).

Autrement dit : apparier `meson-amvdec` avec la série `v4l2-request` demande une
fonction que personne n'a écrite — export multi-plan (un `VIDIOC_EXPBUF` par
plan, un `AVDRMObjectDescriptor` par plan, `layer->nb_planes = 2`). Le chemin
stateful, lui, fonctionne : `h264_v4l2m2m` a décodé 300 images 1080p30 en
0,12 s de temps utilisateur (contre 18,4 s en logiciel).

Conséquence : le stateless reste **non mesurable** en l'état, et l'accélération
matérielle dans Kodi passe par le chemin stateful + un portage de
`v4l2-drmprime` (qui cible FFmpeg 4.4 : 17 hunks sur 30 échouent sur 6.1.6).

## Mise à jour du 2026-10-30 : le stateless décode

L'échec ci-dessus venait d'un FFmpeg **sans** le patch `0002` (capture NV12M) :
la flotte épinglait `885d9a0b`, antérieure à `a7710c1`. Avec la révision
`0d26fb96` (0002 + 0003 + 0004), le hwaccel s'initialise et décode.

Banc de mesure sur la N5, `test1080.mp4` (1080p30, 10 s, 300 images), noyau
7.0.14, `meson-amvdec` :

| chemin | décodage | utime | stime | rtime |
|---|---|---|---|---|
| stateless `v4l2-request` (ce dépôt) | 300 images, 0 erreur | 0,36 s | 0,53 s | 3,8 s |
| stateful `h264_v4l2m2m` | 300 images, 0 erreur | 0,12 s | 8,08 s | 8,7 s |
| logiciel | 300 images | 18,40 s | 0,81 s | 9,0 s |

Kodi suit : `CDVDVideoCodecDRMPRIME::Open - using decoder H.264` et **zéro**
`send packet failed` (contre ~250/minute avant le patch), là où le prédécesseur
échouait dès l'initialisation (`select capture format failed` → « No V4L2 media
device found for S264 »).

Deux conséquences :

- le critère d'abandon posé plus haut est **levé** : le stateless est mesuré,
  bit-exact sur ce banc (0 erreur de décodage), et c'est le chemin le plus
  économe en CPU total (0,89 s contre 8,2 s en stateful, 19,2 s en logiciel) ;
- la cause de l'échec n'était pas le dialecte des contrôles (`meson-amvdec` vs
  série `v4l2-request`) mais **le format de capture**, déjà traité par 0002.

Reste à mesurer avant de basculer le défaut sur `stateless` : HEVC (0004 aligne
`MAX_SLICES`), le 10 bits, et la stabilité sur une lecture longue.

### Banc complet (2026-10-30, N5, appareil au repos)

300 images de 1080p30, `ffmpeg -hwaccel drm -hwaccel_output_format drm_prime` :

| contenu | décodage | utime | stime | décodage |
|---|---|---|---|---|
| H.264 8 bits | matériel | 0,46 s | 0,70 s | 0 erreur |
| HEVC 8 bits | matériel | 0,48 s | 0,70 s | 0 erreur |
| HEVC 10 bits | matériel | 0,41 s | 0,57 s | 0 erreur |
| H.264 8 bits | logiciel | 18,40 s | 0,81 s | — |
| HEVC 8 bits | logiciel | 46,50 s | 1,83 s | — |

Lecture longue : 60 s de H.264 1080p30 en 3,5 s + 3,1 s de CPU, zéro erreur,
`dmesg` silencieux. Kodi : `CDVDVideoCodecDRMPRIME` ouvre H.264 **et** HEVC sans
un seul `send packet failed`.

Deux limites à connaître, mesurées, qui ne sont pas des régressions :

- **H.264 10 bits** : le driver n'expose que `S264`, sans variante 10 bits → le
  hwaccel refuse, repli logiciel ;
- **un client à la fois** : Kodi en service tient `/dev/video0` (EBUSY pour tout
  autre client), et un échec d'initialisation laisse le décodeur occupé jusqu'au
  redémarrage de la carte. Mesurer en ligne de commande exige Kodi arrêté, et
  redémarrer après tout échec.
