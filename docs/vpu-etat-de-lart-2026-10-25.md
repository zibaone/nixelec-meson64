# VPU Meson — état de l'art au 2026-10-25

> **Statut** : veille technique. Rien ici n'est validé sur une image
> `nixelec-meson64`.
> **Périmètre** : décodeur vidéo Amlogic (`meson-vdec`, `meson-amvdec`,
> `aml-vdec`), pas le pipeline display/HDMI.
> **Question** : quelles sont les avancées récentes, y compris hors upstream et
> dans les branches personnelles des développeurs, et que peut-on en faire
> pour `nixelec-meson64` ?

---

## 1. Résumé

Il y a désormais **trois familles de drivers** à distinguer :

| Driver | API | Où | SoCs | Statut |
|---|---|---|---|---|
| `meson-vdec` (staging) | V4L2 M2M **stateful** | Linux upstream | GXBB/GXL/GXLX/GXM/G12A/G12B/SM1 | upstream, mais limité |
| `meson-amvdec` | V4L2 **stateless Request API** | LibreELEC / branches Christian Hewitt | mêmes SoCs + S4 | hors upstream, le plus avancé |
| `aml-vdec` | V4L2 **stateless Request API** | série Amlogic v12 | S4/S805X2 | hors upstream, H.264 seulement |

**Décision du 2026-10-25** : `nixelec-meson64` prend le chemin **stateless**
(backport 7.0 de `meson-amvdec` + `nix-v4l2-request`). Voir
[`decision-vpu-stateless.md`](decision-vpu-stateless.md).

Conclusion courte :

- **Upstream 7.3** : le driver stateful est toujours là, sans HEVC, sans 10-bit
  et sans AFBC. Kodi ne peut l'utiliser qu'avec des patchs FFmpeg
  `v4l2_m2m` + DRM PRIME (LibreELEC), ou en restant en software decode.
- **LibreELEC master** (2026-10-24) porte une **réécriture stateless**
  `meson-amvdec` avec H.264, HEVC Main/Main10, MPEG-2, VP9, AFBC, S4 et
  déinterlaceur. C'est la voie la plus complète pour un NixELEC Meson, mais
  c'est une pile Amlogic hors upstream de 210 patchs (dont ~15 pour le VPU).
- **Amlogic** pousse un driver stateless S4 officiel (v12, 2026-10-22), mais
  H.264 8-bit progressif seulement, et pas encore mergé.
- **S905X4 / SC2** n'a toujours **aucun driver mainline**. Les firmwares
  existent (SC2 AV1, HEVC, VP9), pas le driver.

---

## 2. Upstream : `meson-vdec` stateful

### 2.1 Ce que supporte réellement Linux 7.3

Le driver est dans `drivers/staging/media/meson/vdec/`. Il est **stateful**
(`v4l2_m2m`), pas Request API. `vdec_platform.c` de la v7.3 donne :

| SoC | H.264 | MPEG-1/2 | VP9 | HEVC |
|---|---|---|---|---|
| GXBB | oui | oui | non | non |
| GXL | oui | oui | oui | non |
| GXLX | oui | oui | non | non |
| GXM | oui | oui | oui | non |
| G12A/G12B | oui | oui | oui | non |
| SM1 | oui | oui | oui | non |

Donc **pas de HEVC upstream**, pas de 10-bit, pas d'AFBC. Les patchs HEVC
10-bit existent dans Armbian (et donc dans `nixbian`), pas dans mainline.

### 2.2 Derniers commits upstream

| Date | Commit | Sujet | État |
|---|---|---|---|
| 2026-09-28 | `b3a805dd5a83` | `size capture planes from the aligned canvas` | mergé après v7.3 (7.4) |
| 2026-06-24 | `20aa934ace69` | `fix NULL pointer deref in vdec_try_fmt_common` | mergé |
| 2026-05-20 | `940f161f734b` | `Fix memory leak in error path of vdec_open` | mergé |
| 2026-05-08 | `2a1a564adab1` | `fix typo in codec files` | mergé |
| 2025-08-10 | `277966749f46` et suivants | conversion `file->private_data` → `v4l2_fh` | mergé |
| 2024-06-04 | `0554e280c58b` | `add GXLX SoC platform` | mergé |

Le patch `b3a805dd5a83` est directement lié à Kodi :

- il corrige la taille des plans de capture pour les largeurs non multiples de
  32 ;
- sans lui, `720x360` NV12M déborde et `drmModeAddFB2()` renvoie `-EINVAL` :
  Kodi joue le son sur un écran noir ;
- testé sur **S905X GXL p212** avec LibreELEC 12 sur 6.16-rc3, en **V4L2 m2m +
  DRM PRIME**, 720x360 et 1080p H.264, sans erreur `AddFB2`.

C'est la preuve la plus récente que le chemin **stateful → Kodi** fonctionne
quand les patchs FFmpeg adéquats sont appliqués.

### 2.3 Patchs en attente (patchwork, non mergés au 2026-10-25)

| Date | Auteur | Sujet | Portée |
|---|---|---|---|
| 2026-10-24 | John O'Callaghan | `reset the VLD before H.264 decoding` | staging, G12A/GXBB, H.264 |
| 2026-07-13 | Anand Moon | série v7 19 patchs : lifetimes, races, VIFIFO 32 MiB | staging |
| 2026-07-17 | Alfie Varghese | `propagate devm_clk_get() errors` | staging |
| 2026-07-13 | Alfie Varghese | `fix UAF, memory leak and NULL derefs` | staging |
| 2026-06-27 | Doruk Tan Ozturk | deux fixs de lifetime VP9 | staging |

Le patch de John O'Callaghan est notable :

- il corrige un luma faux jusqu'au second IDR en H.264 ;
- `vdec_1_start()` reset le VDEC avant d'alimenter les mémoires, puis le VLD
  démarre dans un état indéfini ;
- le fix ajoute le reset VLD (`DOS_SW_RESET0` bit 4) dans
  `codec_h264_start()` ;
- testé Radxa Zero (S905Y2, G12A) et Odroid C2 (S905, GXBB), GStreamer et
  FFmpeg `h264_v4l2m2m`, bit-exact après fix ;
- le même fix est dans Armbian PR #11098.

Ces patchs sont sur le **driver stateful**. Ils n'aident pas directement le
nouveau driver stateless de LibreELEC.

---

## 3. Le tournant : `meson-amvdec` stateless dans LibreELEC

### 3.1 Ce que c'est

LibreELEC master (`96d9f0fbda0910197e7a1da9cc20e57538984b6b`, 2026-10-24)
porte une pile Amlogic de **210 patchs** `projects/Amlogic/patches/linux/`,
dont une quinzaine concernent le VPU. Le cœur est :

| Patch | Sujet |
|---|---|
| `amlogic-0117` | suppression du driver staging `meson/vdec` |
| `amlogic-0118` | formats UAPI Amlogic `AM21B` / `AM21C` (FBC) |
| `amlogic-0119` | nouveau `meson-amvdec` stateless, noyau |
| `amlogic-0120` | MPEG-2 |
| `amlogic-0121` | H.264 |
| `amlogic-0122` | HEVC Main / Main10 |
| `amlogic-0123` | VP9 |
| `amlogic-0127` | HEVC compressed basic layout sur GXM (AM21B) |
| `amlogic-0128` | test 4K HEVC sur GXBB |
| `amlogic-0162` | déinterlaceur matériel G12A/G12B/SM1/S4 |
| `amlogic-0208` | bindings `amlogic,s4-vdec` |
| `amlogic-0209` | support S4 + microcode signé / secure monitor |
| `amlogic-0210` | nœud DTS S4 |

Le patch `0119` annonce explicitement :

> Provide a stateless-only V4L2 request interface with mem2mem scheduling,
> control snapshots, timestamp reference lookup and explicit input and
> capture-buffer ownership.

Ce n'est donc plus le driver stateful : c'est une réécriture **stateless**
compatible avec l'API Request, la même famille que `cedrus`/`rkvdec`.

### 3.2 Capacités annoncées

- SoCs : GXBB, GXL, GXLX, GXM, G12A, G12B, SM1, plus **S4**.
- Codecs : MPEG-2, H.264, HEVC Main/Main10, VP9 (VP9 absent GXBB/GXLX).
- Résolutions : jusqu'à 4K (4096x2304) sur G12/SM1 ; H.264 1920x1088 sur GX,
  4K sur GXL/GXM ; HEVC 4K sur tous, avec un patch TESTING pour GXBB.
- Sortie : NV12M linéaire, plus AM21B/AM21C compressed scatter sur les SoCs
  compatibles.
- 10-bit : HEVC Main10 décodé, double-write 8-bit NV12M sur GX ; AM21C sur
  G12/SM1.
- S4 : microcode signé chargé via secure monitor ; le firmware doit d'abord
  être passé à la TA Amlogic par un loader userspace (`amvdec-tee`).
- Déinterlaceur : driver V4L2 M2M séparé (`meson-di`), G12A/G12B/SM1/S4.

Auteurs : Gus Bourg (cœur, MPEG-2, H.264, HEVC, VP9), Christian Hewitt (S4,
déinterlaceur, intégration). Les commits portent des tags
`Assisted-by: Claude` : c'est une production assistée par IA, à traiter comme
du code à relire, pas comme un oracle.

### 3.3 Statut réel

- **Pas upstream.** `drivers/media/platform/amlogic/` dans Linux master ne
  contient que `c3/` et `meson-ge2d/` ; `amvdec/` renvoie 404.
- La série est intégrée dans **LibreELEC master** et dans les branches
  `chewitt/linux` (`amlogic-7.3.y`, tête 2026-10-05/07).
- Elle cible **Linux 7.3** ; `nixbian` edge est en 7.0.14. Un backport est
  donc lourd : ce n'est pas un petit `extraPatches`, c'est un remplacement de
  driver.
- `LibreELEC.tv` utilise un noyau `7.3.0-rc5` (`projects/Amlogic/linux/`).

### 3.4 Côté userspace

Le driver stateless utilise les contrôles V4L2 standard
(`V4L2_CID_STATELESS_H264_*`, `HEVC_*`, `VP9_*`, `MPEG2_*`). Il est donc
destiné à la pile **`v4l2-request`** :

- FFmpeg `h264_v4l2request`, `hevc_v4l2request`, `vp9_v4l2request`,
  `mpeg2_v4l2request` ;
- Kodi `CDVDVideoCodecDRMPRIME` avec le patch `v4l2request-hwdevice` déjà
  présent dans `nix-v4l2-request`.

Mais il y a un piège HEVC : `amvdec` enregistre et **exige**
`V4L2_CID_STATELESS_HEVC_EXT_SPS_ST_RPS` quand le SPS contient des
short-term RPS. La série FFmpeg `v4l2-request` de `nix-v4l2-request` est
basée sur FFmpeg 6.1.6 et ne pose pas ce contrôle. Le chemin H.264 est donc
le plus sûr à court terme ; HEVC demandera probablement un rebase de
`nix-v4l2-request` vers la série LibreELEC actuelle.

---

## 4. La pile stateful + `v4l2-drmprime` (alternative)

Pour le driver **upstream stateful**, LibreELEC fournit un patch FFmpeg
`packages/multimedia/ffmpeg/patches/v4l2-drmprime/0001-v4l2-drmprime.patch` :

- sortie `AVDRMFrameDescriptor` / `AV_PIX_FMT_DRM_PRIME` depuis `v4l2_m2m` ;
- `HW_CONFIG_INTERNAL(DRM_PRIME)` ;
- implémentation `hwcontext` ;
- `DRM_FORMAT_MOD_LINEAR` par défaut ;
- support des formats logiciels quand DRM PRIME n'est pas disponible.

Cette série vient de Lukas Rusak (2018-2021) et est toujours appliquée par
LibreELEC. Elle n'est **pas upstream** : dans FFmpeg master,
`libavcodec/v4l2_m2m_dec.c` n'expose toujours pas `DRM_PRIME` ni `hw_config`.

`chewitt/FFmpeg` a deux branches utiles :

| Branche | Date | Contenu |
|---|---|---|
| `master-drmprime` | 2021-09-01 | `v4l2m2m` DRM PRIME, hwcontext, flush, pixel format |
| `modifiers` | 2026-02-18 | FBC/AM21C pour `meson-vdec` HEVC, coded dimensions, AV1 |

C'est le chemin utilisé par le test de Michael Freidkin (S905X GXL, Kodi,
V4L2 m2m + DRM PRIME). Il est plus simple en nombre de patchs noyau que le
driver stateless, mais il plafonne aux codecs du driver stateful upstream :
H.264/MPEG-2/VP9, et HEVC seulement via les patchs Armbian.

---

## 5. Le driver S4 officiel d'Amlogic (v12)

Série patchwork `1191018`, **v12**, 2026-10-22, 6 patchs :

1. `firmware: meson: sm: video firmware loading via secure monitor`
2. `firmware: meson: sm: Add video firmware loading SMC call`
3. `media: dt-bindings: Add Amlogic V4L2 video decoder`
4. `decoder: Add V4L2 stateless H.264 decoder driver`
5. `arm64: dts: amlogic: Add video decoder driver support for S4 SOCs`
6. `arm64: defconfig: Enable CONFIG_VIDEO_AMLOGIC_VDEC`

Caractéristiques :

- nouveau `drivers/media/platform/amlogic/vdec/`, pas `amvdec` ;
- architecture sans ESPARSER, entrée directe par buffers vb2 ;
- **stateless V4L2 M2M** ;
- H.264 **8-bit progressif seulement**, jusqu'à 1920x1088 sur S805X2 ;
- NV12/NV21, mmap et dma-buf, Annex B ;
- firmware signé : la TA TEE décrypte/décompose le package, le secure monitor
  charge le microcode dans l'AMRISC via SMC ;
- testé GStreamer `v4l2slh264dec` ;
- `v4l2-compliance` 1.30.1 : 49/49, 0 warning, détecté comme
  « Detected Stateless Decoder » ;
- **pas mergé** au 2026-10-25 (v12 « new »).

C'est le chemin officiel Amlogic pour S4 (S805X2/S905Y4), pas pour S905X4
(SC2). Il ne couvre que H.264 pour l'instant.

---

## 6. Autres branches et dépôts

| Dépôt / branche | Date | Intérêt | Statut |
|---|---|---|---|
| `chewitt/linux` `amlogic-7.3.y` | 2026-10-05/07 | `amvdec` + S4 + OP-TEE + display/audio/GPU/MMC | WIP, non upstream |
| `chewitt/linux` `meson-vdec` | 2026-03-31 | 16 fixs stateful : MPEG1/2 dyn. res, esparser, VP9 backpressure | WIP, non upstream |
| `chewitt/linux` `amlogic-6.13-vdec-v2` | 2025-02 | AFBC/compressed, HEVC/MPEG2 G12A, 10-bit | WIP, précurseur |
| `chewitt/linux` `amlogic-vdec` | 2023 | stateless HEVC WIP | WIP, ancien |
| `chewitt/FFmpeg` `master-drmprime` | 2021 | v4l2m2m + DRM PRIME | utilisé par LibreELEC |
| `chewitt/FFmpeg` `modifiers` | 2026-02-18 | FBC/AM21C, coded dims, AV1 | WIP |
| `LibreELEC/meson-firmware` `stateless` | 2026-10-07 | `video_ucode.bin`, TA S905Y4, microcodes multi | firmware |
| `jefflessard/meson-vdec-extra` | 2025-08 | firmware SC2/T7/T5D/T3/TM2 (AV1/HEVC/VP9) extrait du vendor 5.15.170 | firmware seul |
| `ray38080289/meson-sm1-codecs` | 2026-10-09 | SM1 stateful : MPEG1/2/H.264/HEVC/VP9 decode + H.264/HEVC encode, FFmpeg/GStreamer | 100 % IA, hors upstream, 1 carte |
| `CoreELEC/linux-amlogic` `6.12.69_202606` | 2026-10-21 | vendor 6.12, DTS S4/T7 | vendor |
| `CoreELEC/linux-amlogic` `5.15.196_20260306` | 2026-10-21 | vendor 5.15 | vendor |
| `armbian/firmware` `41795d0` | 2026-10-14 | ajout des blobs `meson/vdec/*` standard | firmware |
| `warpme/minimyth2` `40a741a` | 2026-10-17 | packaging S4 `video_ucode.bin` + multi | packaging |
| `superna9999/linux` | — | branches VPU/display anciennes (v4.9–v5.9) | pas de vdec récent |
| `Kwiboo/linux`, `jernejsk/linux` | — | pas de travail Meson VPU récent identifié | — |

`ray38080289/meson-sm1-codecs` mérite une mention à part :

- driver stateful `meson-vdec` SM1 avec beaucoup de fixs ;
- décode MPEG-1/2, H.264, HEVC 8/10-bit, VP9 jusqu'à 4K ;
- encode H.264 et HEVC via V4L2 M2M ;
- FFmpeg `*_v4l2m2m` et GStreamer ;
- testé sur HK1 X3 (S905X3) ;
- **100 % généré par IA**, pas upstream, une seule carte, firmware vendor
  spécifique. À considérer comme une source d'idées, pas comme une base.

---

## 7. Firmware

| Source | Contenu | Usage |
|---|---|---|
| linux-firmware | `meson/vdec/*.bin` GX/G12/SM1 | driver stateful upstream |
| `armbian/firmware` 2026-10-14 | mêmes blobs, ajoutés au dépôt Armbian | nixbian |
| `LibreELEC/meson-firmware` | `*_multi.bin`, `video_ucode.bin`, TA S905Y4 | `amvdec` stateless, S4 |
| `jefflessard/meson-vdec-extra` | SC2/T7/T5D/T3/TM2 AV1/HEVC/VP9 | pas de driver mainline |
| `warpme/minimyth2` | packaging S4 | distribution |

Point important : **le firmware SC2/T7 existe** (AV1, HEVC, VP9) mais **le
driver mainline SC2/T7 n'existe pas**. Avoir le blob ne suffit pas.

---

## 8. Conséquences pour `nixelec-meson64`

### 8.1 Trois chemins possibles

| Chemin | Noyau | Userspace | Avantages | Coûts / risques |
|---|---|---|---|---|
| **A. Stateful** | 7.0 + patches Armbian HEVC/10-bit/FBC | FFmpeg `v4l2-drmprime` + Kodi 21.3 | peu de patchs noyau, testé S905X/Kodi | HEVC/10-bit/FBC via Armbian, pas mainline ; patch FFmpeg hors upstream ; **repli** |
| **B. LibreELEC stateless** | 7.0 + sous-ensemble vdec (ou 7.3) | `nix-v4l2-request` (FFmpeg Request + Kodi) | H.264/HEVC/VP9/MPEG2, 10-bit, AFBC, S4 | driver hors upstream, FFmpeg à rebaser, validation ; **retenu** |
| **C. Amlogic S4 v12** | 7.3 + série v12 | GStreamer / FFmpeg stateless | voie officielle S4, TEE | H.264 seulement, 1080p, pas S905X4, pas mergé |

### 8.2 Décision retenue — stateless

**Décision du 2026-10-25 : `nixelec-meson64` prend le chemin stateless.**

1. Garder le noyau `nixbian` meson64 **7.0** et backporter le sous-ensemble
   `amlogic-0118` à `0128`.
2. Désactiver le staging (`CONFIG_VIDEO_MESON_VDEC=n`) et activer
   `CONFIG_VIDEO_MESON_AMVDEC=m`.
3. Packager les firmwares `meson/vdec/*_multi.bin` / `*_mmu.bin` depuis
   `LibreELEC/meson-firmware`.
4. Utiliser `nix-v4l2-request` : H.264 d'abord.
5. Rebaser FFmpeg pour `EXT_SPS_ST_RPS`/`LT_RPS` avant de promettre HEVC.
6. **Ne pas promettre S905X4/SC2.** Le firmware existe, le driver non.
7. S4/S905Y4 reste hors périmètre : les deux voies S4 bougent, mais ce n'est
   pas le même SoC que le S905X4.

Patchs prêts : `patches/kernel/meson64-vdec-7.0/`.
Décision et gates : [`decision-vpu-stateless.md`](decision-vpu-stateless.md).

### 8.3 Backport 7.0 ou plateforme 7.3 ? Essai réel

Un essai a été fait sur le noyau **7.0.14** de `nixbian`
(`meson64-edge`, config Armbian) :

- patchs `amlogic-0118` à `amlogic-0128` appliqués (le hunk `MAINTAINERS` de
  `0119` a été retiré : conflit cosmétique) ;
- `CONFIG_VIDEO_MESON_AMVDEC=m` ajouté ;
- build croisé aarch64 avec le helper `buildKernel` de `nixbian`.

Résultat : **le module `meson-amvdec.ko` compile** (455 344 octets), le noyau
et les modules sont produits. Le patch `0117` (suppression du staging) n'a pas
été appliqué : le driver staging reste compilé, donc en production il faut
soit le supprimer, soit désactiver `CONFIG_VIDEO_MESON_VDEC` pour éviter deux
drivers sur le même compatible. Aucun test matériel du backport n'a été fait.

Depuis, la N5 a booté en LibreELEC 6.14.2 (2026-10-26). Le SoC mesuré est un
**S905L/GXL**, pas un S905X. Le driver stateful expose `H264`, `HEVC` et
`VP90` sur `/dev/video0` avec le DTB p212, mais aucun décodage n'a encore été
mesuré avec `meson-amvdec` ni avec `nix-v4l2-request`. Voir
[`boards/magicsee-n5.md`](boards/magicsee-n5.md).

Conclusion : **le backport 7.0 est techniquement plus simple que prévu**.
Les patchs sont essentiellement de nouveaux fichiers ; l'API V4L2 Request
utilisée (`v4l2_ctrl_request_*`, `allow_cache_hints`, contrôles HEVC étendus)
existe déjà dans 7.0. Le vrai coût n'est pas le patch noyau, c'est
firmware + FFmpeg + validation.

| Tâche | Backport 7.0 | Nouvelle plateforme 7.3 |
|---|---|---|
| Patchs noyau vdec (0118-0128) | 1–2 j (appliqués, compilés) | 1–2 j (probablement propres) |
| Config / désactivation staging | 0,5 j | 3–5 j (plateforme + config + CI) |
| Firmware multi (`*_multi.bin`) | 0,5–1 j | 0,5–1 j |
| Userspace H.264 (`nix-v4l2-request`) | 2–4 j | 2–4 j |
| HEVC/VP9 (rebase FFmpeg RPS étendus) | 3–6 j | 3–6 j |
| CI / cache ARM | 1–2 j | 2–3 j |
| Validation matérielle | 2–4 j | 2–4 j |
| **Total H.264** | **~1–2 semaines** | **~2–3 semaines** |
| **Total HEVC/VP9/10-bit** | **~3–5 semaines** | **~4–6 semaines** |

Pour le stateful 7.0 + `v4l2-drmprime`, compter 1–2 semaines, mais sans HEVC
10-bit ni AFBC.

**Note** : cet essai est la base du chemin **stateless retenu**. Il prouve que
le noyau 7.0 n'est pas un obstacle technique ; il reste à packager le
firmware, à brancher `nix-v4l2-request` et à valider sur matériel.

### 8.4 Gates de validation VPU

- [ ] `/dev/video*` expose `H264_SLICE` (stateless) ou `H264` (stateful) ;
- [ ] `v4l2-compliance` passe ;
- [ ] `ffmpeg -c:v h264_v4l2request` décode sans fallback ;
- [ ] Kodi log : création d'un hwdevice `V4L2REQUEST` (ou `DRM` pour
      `v4l2_m2m`) ;
- [ ] comparaison MD5/PSNR avec décodage logiciel ;
- [ ] charge CPU par cœur nettement sous 100 % sur un 1080p H.264 ;
- [ ] 1080p HEVC et VP9 ;
- [ ] 10-bit si le chemin B est retenu ;
- [ ] pas d'erreur `drmModeAddFB2` / écran noir.

---

## 9. Sources

### Upstream

- `torvalds/linux` `drivers/staging/media/meson/vdec/`
- commit `b3a805dd5a83ba8c85e2085d3411eb9975e0aea4` (aligned canvas)
- commit `20aa934ace6917262ff579a73ec018d06a7bad1c` (NULL deref)
- tag `v7.3` `c03c1a14507d`
- patchwork `linux-media` :
  - `14912387` John O'Callaghan, VLD reset
  - série `1126615` Anand Moon
  - `14692430` Alfie Varghese
  - `14906991` série S4 v12 (patch 4/6)
  - série `1191018` S4 stateless v12

### LibreELEC

- `LibreELEC/LibreELEC.tv` `96d9f0fbda0910197e7a1da9cc20e57538984b6b`
  (2026-10-24)
- `projects/Amlogic/patches/linux/amlogic-0117` … `amlogic-0210`
- `projects/Amlogic/patches/linux/amlogic-0119-media-amlogic-add-the-video-decoder-core.patch`
- `projects/Amlogic/patches/linux/amlogic-0209-media-amlogic-amvdec-add-S4-support.patch`
- `packages/multimedia/ffmpeg/patches/v4l2-drmprime/0001-v4l2-drmprime.patch`
- `projects/Amlogic/patches/kodi/kodi-0007` … `kodi-0011`

### Branches personnelles / firmwares

- `chewitt/linux` : `amlogic-7.3.y`, `meson-vdec`,
  `amlogic-6.13-vdec-v2`, `amlogic-vdec`
- `chewitt/FFmpeg` : `master-drmprime`, `modifiers`
- `chewitt/amvdec-tee` : loader TEE pour microcode signé
- `LibreELEC/meson-firmware` : branche `stateless`
- `jefflessard/meson-vdec-extra` : commit `f23e523`
- `ray38080289/meson-sm1-codecs` : commit `eb7a444`
- `armbian/firmware` : commit `41795d0`
- `warpme/minimyth2` : commit `40a741a`
- `CoreELEC/linux-amlogic` : branches `6.12.69_202606`,
  `5.15.196_20260306`

### `nix-v4l2-request`

- `pkgs/ffmpeg-v4l2request/patches/0001-v4l2-request-ffmpeg-6.1.6.patch`
- `pkgs/kodi/patches/0001-DVDVideoCodecDRMPRIME-v4l2request-hwdevice.patch`
- Limite identifiée : pas de `V4L2_CID_STATELESS_HEVC_EXT_SPS_ST_RPS`.
