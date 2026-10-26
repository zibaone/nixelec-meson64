# VPU stateless — `meson-amvdec` sur Linux 7.0

Sous-ensemble du jeu de patchs LibreELEC `projects/Amlogic/patches/linux`
(`amlogic-0118` à `amlogic-0128`), destiné à un noyau **7.0** de `nixbian`.

## Source

- dépôt : `LibreELEC/LibreELEC.tv`
- commit : `96d9f0fbda0910197e7a1da9cc20e57538984b6b` (2026-10-24)
- répertoire : `projects/Amlogic/patches/linux/`
- auteurs : Gus Bourg, Christian Hewitt ; les patches portent des tags
  `Assisted-by: Claude`
- licence : GPL-2.0 (code noyau)

## Pourquoi ce sous-ensemble

Le driver `meson-amvdec` remplace l'interface **stateful** du staging par une
interface **V4L2 stateless Request API**. Il couvre GXBB/GXL/GXLX/GXM/G12A/
G12B/SM1 et les codecs MPEG-2, H.264, HEVC Main/Main10 et VP9.

Le patch `0117` de suppression du staging n'est **pas** inclus : on désactive
le driver staging par configuration (`CONFIG_VIDEO_MESON_VDEC=n`). Cela évite
deux drivers sur le même compatible sans conflit de patch.

Le patch `0119` a été modifié : son hunk `MAINTAINERS` a été retiré. C'est un
conflit cosmétique avec l'arbre 7.0 ; il n'apporte rien au build.

## État vérifié

- les patchs s'appliquent au noyau `linux-7.0.14` de `nixbian`
  (`meson64-edge`, config Armbian) ;
- avec `CONFIG_VIDEO_MESON_AMVDEC=m`, le build croisé aarch64 produit
  `meson-amvdec.ko` (455 344 octets) ;
- la N5 a booté LibreELEC 6.14.2 en **stateful** le 2026-10-26 (S905L/GXL,
  DTB p212) ; **aucun test matériel du driver stateless** n'a été fait ;
- le sous-ensemble S4 (`0209`/`0210`) n'est pas inclus : S4 dépend aussi de
  display/audio/GPU/OP-TEE et de la pile LibreELEC 7.3.

## Firmware requis

Le driver charge des microcodes `*_multi.bin` / `*_mmu.bin` qui ne sont pas
tous dans `linux-firmware` :

- `meson/vdec/gxl_h264_multi.bin`
- `meson/vdec/g12a_h264_multi.bin`
- `meson/vdec/sm1_h264_multi.bin`
- `meson/vdec/gxl_mpeg12_multi.bin`
- `meson/vdec/g12a_hevc_mmu.bin`
- `meson/vdec/sm1_hevc_mmu.bin`
- `meson/vdec/gxl_vp9.bin`
- `meson/vdec/g12a_vp9.bin`
- `meson/vdec/sm1_vp9_mmu.bin`
- `meson/vdec/video_ucode.bin` (S4 uniquement, hors périmètre ici)

Source recommandée : `LibreELEC/meson-firmware`, branche `stateless`
(commit `662b843`, 2026-10-07). Vérifier la licence Amlogic avant
redistribution.

## Userspace

- **H.264** : `nix-v4l2-request` (FFmpeg `h264_v4l2request` + Kodi) devrait
  suffire.
- **HEVC** : `amvdec` exige `V4L2_CID_STATELESS_HEVC_EXT_SPS_ST_RPS` ; la
  série FFmpeg 6.1.6 de `nix-v4l2-request` ne le pose pas. Il faut rebaser
  `nix-v4l2-request` vers une série LibreELEC récente avant de promettre
  HEVC.
- **VP9/MPEG-2** : contrôles présents dans la série 6.1.6, mais non validés
  avec Kodi.

## Ordre d'application

Utiliser `series` (ou `series.conf` dans nixbian) avec `quilt` ou comme liste
ordonnée de `kernelPatches`/`extraPatches`. Ne pas réordonner : `0119` crée
les fichiers que `0120`+ modifient.
