# Plan VPU — chemin stateful (archivé)

> **Archivé le 2026-10-25.** Cette décision est remplacée par le chemin
> **stateless**. Voir [`../decision-vpu-stateless.md`](../decision-vpu-stateless.md).
>
> Conservé pour mémoire : c'est la solution de repli si le stateless échoue.
>
> **Décision d'origine** : `nixelec-meson64` prend le chemin **stateful**.
> Le chemin stateless LibreELEC restait documenté comme veille/option.

---

## 1. Pile retenue

```text
noyau nixbian meson64 (7.0 edge)
  └── meson-vdec (V4L2 M2M stateful, staging upstream + patches Armbian)
        └── FFmpeg v4l2_m2m + DRM PRIME (patch LibreELEC v4l2-drmprime)
              └── Kodi 21.3 GBM / CDVDVideoCodecDRMPRIME
```

Ce n'est **pas** la pile `nix-v4l2-request` stateless. `nix-v4l2-request`
reste utilisé pour sunxi64, et pourra resservir plus tard si le driver
stateless `amvdec` est adopté.

Périmètre : GXBB/GXL/GXLX/GXM/G12A/G12B/SM1, donc S905X, S905X2, S905X3,
S905D, S912, A311D, S922X.

Hors périmètre : S905X4/SC2, S4/S905Y4, T7/VIM4.

---

## 2. Noyau

### 2.1 Base

- `nixbian` meson64 `edge` 7.0.14, mode `armbian` ;
- `CONFIG_VIDEO_MESON_VDEC=m` déjà présent dans la config meson64 ;
- ne pas activer `VIDEO_MESON_AMVDEC` ;
- conserver le driver staging : c'est lui qui expose `/dev/video*` stateful.

### 2.2 Patchs à backporter

Le noyau 7.0 de `nixbian` est antérieur à plusieurs correctifs importants pour
Kodi. Le minimum à ajouter au jeu meson64 :

| Patch | Pourquoi |
|---|---|
| `b3a805dd5a83` `size capture planes from the aligned canvas` | évite le débordement NV12M et l'écran noir Kodi sur les largeurs non multiples de 32 ; mergé upstream après 7.3 |
| John O'Callaghan, `reset the VLD before H.264 decoding` (2026-10-24) | corrige le luma faux jusqu'au second IDR, surtout G12A |
| Doruk Tan Ozturk, fixs VP9 use-after-free (2026-06-27) | stabilité VP9 |
| Alfie Varghese, UAF/leak/NULL + `devm_clk_get()` (2026-07) | stabilité/erreurs de probe |
| Anand Moon, série v7 (2026-07-13) | optionnel : lifetimes/races, VIFIFO 32 MiB ; à sélectionner, pas à prendre en bloc |

Les patchs Armbian déjà présents dans `nixbian` ajoutent HEVC (8/10-bit) et
l'AM21C/FBC. Ils restent la base codec. Ne pas les remplacer par `amvdec`.

### 2.3 Config et modules

- `CONFIG_VIDEO_MESON_VDEC=m` ;
- `CONFIG_MEDIA_SUPPORT=m`, `CONFIG_V4L2_MEM2MEM_DEV=y` (déjà) ;
- garder `meson-vdec` dans l'allowlist d'élagage des modules ;
- `CONFIG_CMA_SIZE_MBYTES=128` : à augmenter si 4K/10-bit ou si Kodi manque
  de CMA. Mesurer avant de figer (`cma=256M` ou plus) ;
- ne pas ajouter `CONFIG_VIDEO_MESON_AMVDEC`.

### 2.4 Firmware

Blobs standard `linux-firmware`, sous `meson/vdec/` :

- `gxl_h264.bin`, `gxl_hevc.bin`, `gxl_hevc_mmu.bin`, `gxl_vp9.bin`,
  `gxl_mpeg12.bin` ;
- `g12a_h264.bin`, `g12a_hevc_mmu.bin`, `g12a_vp9.bin` ;
- `sm1_hevc_mmu.bin`, `sm1_vp9_mmu.bin` ;
- `gxm_h264.bin`, `gxbb_h264.bin`.

Vérifier que le firmware de famille `meson64` les inclut réellement
(`buildFirmware` copie `meson64`/`meson`/`bt`, et
`hardware.enableRedistributableFirmware` ajoute linux-firmware). Sinon,
ajouter un `firmware_include` explicite.

---

## 3. Userspace

### 3.1 FFmpeg

Le patch nécessaire est **`v4l2-drmprime`** de LibreELEC
(`packages/multimedia/ffmpeg/patches/v4l2-drmprime/0001-v4l2-drmprime.patch`).
Il ajoute :

- `AVDRMFrameDescriptor` / `AV_PIX_FMT_DRM_PRIME` en sortie de `v4l2_m2m` ;
- `HW_CONFIG_INTERNAL(DRM_PRIME)` ;
- `hwcontext` ;
- `DRM_FORMAT_MOD_LINEAR`.

Il n'est pas upstream. Il faut le porter sur le FFmpeg utilisé par Kodi 21.3
(FFmpeg 6.1.x), ou passer à un FFmpeg plus récent si le patch s'y applique
mieux.

Emplacement recommandé : **`nix-v4l2-request`**, comme nouveau paquet
`ffmpeg-v4l2m2m` + variante Kodi, sans toucher aux paquets stateless existants.
Sinon, paquet local dans `nixelec-meson64/packages/`.

### 3.2 Kodi

- Kodi 21.3 GBM, `CDVDVideoCodecDRMPRIME` ;
- `videoplayer.useprimedecoder = true` (déjà dans le patch Kodi de
  `nix-v4l2-request`, mais à vérifier pour la variante stateful) ;
- le patch Kodi `v4l2request-hwdevice` n'est pas indispensable pour
  `v4l2_m2m` si le device type reste `DRM`, mais ne gêne pas ;
- le profil `kodi-gbm` de `nixelec-sunxi64` est réutilisable.

### 3.3 Ce qu'il ne faut pas faire

- ne pas sélectionner `h264_v4l2request` / `hevc_v4l2request` : ce sont les
  décodeurs stateless ;
- ne pas activer `CONFIG_VIDEO_MESON_AMVDEC` ;
- ne pas utiliser le driver staging et `amvdec` en même temps.

---

## 4. Intégration `nixelec-meson64`

`modules/family/meson64.nix` :

- `nixelec.kernelPackage` = noyau de famille `nixbian` meson64-edge ;
- `boot.kernelModules` : `meson-vdec` si nécessaire (sinon udev) ;
- allowlist d'élagage : `meson-vdec`, `meson-drm`, `snd-soc-meson-gx`,
  `cec-meson-ao`, `lima`, `panfrost`, `dw-hdmi-i2s-audio`,
  `snd-soc-hdmi-codec` ;
- `hardware.graphics.enable = true` ;
- CMA par carte.

`modules/profiles/kodi-gbm.nix` : profil existant, avec la variante Kodi
stateful.

`parts/modules.nix` : le module `kodi-gbm` ne doit pas imposer
`v4l2request` ; il doit accepter le paquet Kodi stateful.

---

## 5. Phases

### Phase A — noyau

- backporter `b3a805dd5a83` + VLD reset ;
- construire le noyau et vérifier `meson-vdec.ko` ;
- `v4l2-ctl --list-formats-out` doit lister H264, HEVC, VP9 ;
- `v4l2-compliance` sur le device.

### Phase B — userspace H.264

- paquet FFmpeg `v4l2-drmprime` ;
- Kodi stateful ;
- lecture H.264 1080p, mesure CPU, log Kodi (hwdevice) ;
- comparaison MD5/PSNR avec décodage logiciel.

### Phase C — HEVC/VP9

- HEVC 8-bit puis 10-bit ;
- VP9 ;
- vérifier la taille/les formats de capture et l'absence d'erreurs
  `drmModeAddFB2` ;
- CMA si nécessaire.

### Phase D — robustesse

- patchs VP9 UAF, leaks, erreurs de probe ;
- veille Anand Moon/Alfie Varghese ;
- tests longues durées, seek, changement de résolution.

---

## 6. Gates

- [ ] `v4l2-ctl --list-formats-out` expose H264/HEVC/VP9 ;
- [ ] `v4l2-compliance` passe ;
- [ ] `ffmpeg -c:v h264_v4l2m2m` décode sans fallback ;
- [ ] `ffmpeg -c:v hevc_v4l2m2m` décode 1080p 8-bit ;
- [ ] `ffmpeg -c:v vp9_v4l2m2m` décode ;
- [ ] Kodi crée un hwdevice DRM/DRM_PRIME et ne décode pas en CPU ;
- [ ] MD5/PSNR identiques au logiciel (ou écart documenté) ;
- [ ] charge CPU par cœur nettement sous 100 % en 1080p H.264 ;
- [ ] pas d'erreur `drmModeAddFB2`, pas d'écran noir ;
- [ ] 10-bit : soit validé, soit explicitement non supporté.

---

## 7. Effort

| Tâche | Estimation |
|---|---|
| Patchs noyau ciblés + build | 2–4 j |
| FFmpeg `v4l2-drmprime` + Kodi | 3–5 j |
| Intégration `nixelec-meson64` | 1–2 j |
| Validation H.264 + HEVC + VP9 | 3–5 j |
| Robustesse / 10-bit / longues durées | 3–5 j |
| **Total première version** | **~1,5–2,5 semaines** |
| **Total avec 10-bit et robustesse** | **~3–4 semaines** |

Hypothèse : une personne, matériel disponible, builds ARM déjà outillés.

---

## 8. Risques

- **Le driver stateful reste upstream mais limité** : HEVC/10-bit/AFBC
  dépendent des patchs Armbian, pas de mainline.
- **Le patch FFmpeg `v4l2-drmprime` n'est pas upstream** : il faudra le
  maintenir ou passer à une autre intégration.
- **Kodi 21.3** : le chemin DRM PRIME + `v4l2_m2m` doit être validé sur la
  version nixpkgs ; le profil sunxi ne prouve pas le chemin stateful.
- **Bugs connus** : VLD non reset (luma faux au premier IDR), UAF VP9,
  lifetimes/races. Les patchs listés en §2.2 sont nécessaires, pas optionnels.
- **S905X4/SC2** : aucun driver, même en stateful.
- **U-Boot/DTB** : le VPU ne débloque pas les gaps boot/DTB de `nixbian` ;
  ils restent des prérequis de l'image.
