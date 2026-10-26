# Branches et partage entre familles

## Principe

Trois couches, trois dépôts, **pas un dépôt par SoC** :

| Dépôt | Rôle | Contenu famille |
|---|---|---|
| `nixbian` | noyau, DTB, U-Boot, firmware | patchs et config par famille (`meson64`, `sunxi64`, …) |
| `nix-v4l2-request` | userspace Request API | FFmpeg + Kodi, **agnostique du SoC** |
| `nixelec-meson64` | appliance Meson | modules boards/profils GXL/G12/SM1 |

Le driver VDEC reste dans le noyau (`nixbian`) ; `nix-v4l2-request` ne doit
pas absorber de code noyau ni de logique par famille.

## Les familles Meson ensemble ?

Oui, dans **un seul `nixelec-meson64`** :

- GXL : S905L (Magicsee N5, mesuré), S905X, S905D/W ;
- G12A/G12B : S905X2, S922X/A311D ;
- SM1 : S905X3, S905D3.

Le même jeu de patchs `meson-amvdec` couvre GXBB/GXL/GXLX/GXM/G12A/G12B/SM1.
Ce qui change par famille :

- le DTB ;
- le firmware (`gxl_h264_multi.bin`, `g12a_h264_multi.bin`,
  `sm1_h264_multi.bin`, etc.) ;
- les capacités (VP9 absent sur GXBB/GXLX, limites H.264/HEVC) ;
- le module board.

Donc : **une branche de dev, plusieurs modules board**. Pas de
`nixelec-meson64-gxl` / `-g12` / `-sm1`.

## Et `nix-v4l2-request` ?

Un seul dépôt, une seule pile :

- FFmpeg `h264_v4l2request`, `hevc_v4l2request`, `vp9_v4l2request`,
  `mpeg2_v4l2request` ;
- Kodi `CDVDVideoCodecDRMPRIME` + patch `v4l2request-hwdevice` ;
- les mêmes paquets pour sunxi64 (cedrus), meson64 (amvdec) et rockchip
  (rkvdec).

Les différences se gèrent par :

- des tests par driver (`hwconfig`, `meson-h264`, `meson-hevc`) ;
- des patchs de compatibilité FFmpeg si un driver expose des contrôles plus
  récents ;
- des branches **par version FFmpeg**, pas par SoC.

## Branches proposées

| Dépôt | Branche | Rôle | Merge vers `main` quand |
|---|---|---|---|
| `nixbian` | `feat/meson64-vdec-7.0` | patchs 0118-0128, config, firmware | boot + H.264 bit-exact sur N5 |
| `nix-v4l2-request` | `dev/meson-amvdec` | H.264 d'abord, puis RPS HEVC | H.264 validé sur N5 |
| `nixelec-meson64` | `dev/vpu-stateless` | board N5, image, intégration | boot N5 + Kodi V4L2REQUEST |
| `nixelec-meson64` | `main` | docs + base stable | — |

Branches optionnelles :

- `wip/n5-bringup` : relevés matériels, DTBs testés, UART, WiFi, avant le
  noyau stateless ;
- `dev/ffmpeg-9-rps` : rebase FFmpeg pour
  `V4L2_CID_STATELESS_HEVC_EXT_SPS_ST_RPS`/`LT_RPS`.

## Ordre de merge

```text
nixbian feat/meson64-vdec-7.0
        ↓
nix-v4l2-request dev/meson-amvdec
        ↓
nixelec-meson64 dev/vpu-stateless
        ↓
nixelec-meson64 main
```

On ne merge pas `nixelec` avant que le noyau et le userspace soient validés :
sinon on fige une image qui ne décode pas.

## Gates de merge

- **nixbian** : kernel build, `meson-amvdec.ko`, DTB avec nœud `vdec`, staging
  désactivé, firmware présent.
- **nix-v4l2-request** : `hwconfig`, H.264 `H264_SLICE`, décodage MD5/PSNR.
- **nixelec** : cold boot N5, `/dev/dri`, Kodi GBM, CEC/audio, puis VPU.

## Tags

- `vpu-h264-n5` : premier H.264 bit-exact sur Magicsee N5.
- `vpu-hevc-n5` : HEVC après rebase RPS.
- Ensuite G12B/SM1, sans changer de dépôt.

## S905X4/SC2

Hors de ces branches. Un projet `nixelec-meson-sc2` séparé est justifié :
autre SoC, vendor U-Boot, autre driver VDEC, autre firmware. Ne pas mélanger
avec `nixelec-meson64`.
