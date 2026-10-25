# Décision — VPU stateless

> **Date** : 2026-10-25.
> **Statut** : décidé, non implémenté dans une image.
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
   - intégrer `patches/kernel/meson64-vdec-7.0` au noyau `meson64-edge`
     (ou à une variante `meson64-vdec` pour ne pas impacter les autres
     familles) ;
   - désactiver le staging ;
   - packager les firmwares `*_multi.bin` / `*_mmu.bin` ;
   - vérifier le DTB : nœud `vdec` présent et actif.
2. **nixelec-meson64**
   - créer le squelette flake ;
   - carte de référence : Le Potato (S905X/GXL) ou Radxa Zero 2 (G12B) ;
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
- Aucun test matériel n'a encore été fait.
- S4/SC2/T7 ne sont pas couverts par ce backport.

## Critère d'abandon

Si H.264 ne produit pas un décodage bit-exact avec `V4L2REQUEST` sur une carte
de référence après le backport, on revient au chemin stateful
`v4l2_m2m` + `v4l2-drmprime` et on documente la limite.
