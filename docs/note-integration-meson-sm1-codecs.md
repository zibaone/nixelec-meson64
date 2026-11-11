# Note — intégrer `meson-sm1-codecs` (Amlogic SM1)

> **Statut** : proposition, non validée. **Date** : 2026-11-04.
> **Source** : `github.com/ray38080289/meson-sm1-codecs`, HEAD `eb7a4446` (2026-10-09),
> licence GPL-2.0. Testé par l'auteur sur HK1 X3 (S905X3), noyau 6.18.55-ophub.
> **Périmètre** : devices **SM1** (S905X3 / S905D3) de la couche `nixelec-meson64`.

## 0. Le piège de périmètre — à lire avant tout

| Génération | SoCs | Devices | Dans la flotte |
|---|---|---|---|
| **GXL** | S905L / S905X / S905W | Magicsee N5 | **oui** (seule cible Amlogic) |
| **SM1** | **S905X3 / S905D3** | HK1 X3, X96 Max+ (S905X3) | non |
| **SC2** | **S905X4** | — | non (hors périmètre, cf. `docs/etude-meson64.md`) |

- **SM1 n'est pas le S905X4.** Le S905X4 est **SC2**, génération suivante, sans DTS
  mainline ni carte dans `nixbian` — déjà tranché comme projet vendor séparé.
- **La N5 est GXL S905L** (mesuré, `docs/boards/magicsee-n5.md`), pas SM1. Le driver
  `meson-sm1-codecs` n'est donc **pas applicable à la N5 en l'état** :
  - son `vdec/` est le `meson-vdec` **stateful** (staging) avec des correctifs SM1 ;
    la N5 utilise déjà `meson-amvdec` **stateless** (amlogic-0118..0128), qualifié
    bit-exact en H.264/HEVC/VP9 ;
  - ses encodeurs sont testés sur SM1 uniquement, avec des firmwares SM1 ;
    l'encodeur H.264 de GXL (s'il existe) et le WAVE420L HEVC ne sont pas couverts.
- **Conclusion** : cette note prépare l'intégration pour une **cible SM1**. Sans cible
  SM1 dans la flotte, elle reste une préparation, pas un chantier.

## 1. Ce que le projet apporte

| Élément | Modules | Rôle | Mesures auteur (HK1 X3) |
|---|---|---|---|
| `vdec/` | `meson-vdec` | décodeur staging + correctifs SM1 (MPEG-1/2 multi-instance, HEVC/VP9/H.264, drain/EOS) | H.264 1080p 113 fps, HEVC 167 fps, VP9 186 fps ; 4K H.264 ~40 fps |
| `venc-h264/` | `amvenc_avc`, `meson-venc-h264` | encodeur H.264 Amlogic HCodec, V4L2 M2M + CLI `venc` | 1080p ~58 fps, ~43 dB à 6 Mbit/s |
| `venc-hevc/` | `amvenc_hevc`, `meson-venc-hevc` | encodeur HEVC Chips&Media WAVE420L, V4L2 M2M | 1080p ~59 fps ; 4K ~11 fps (raw input bound) |
| `get-firmware.py` | — | télécharge les ucodes (CoreELEC `media_modules-aml`, starfive `soft_3rdpart`, linux-firmware), md5 pinnés | — |

Firmware : `sm1_mpeg12_multi.bin`, `sm1_hevc_mmu_multi.bin`, `ga_h264_enc_cabac.bin`,
`monet.bin` (+ licence Chips&Media), `g12a_h264.bin`, `sm1_vp9_mmu.bin`.
Le README avertit : **un autre ucode `video_ucode.bin` parle un protocole différent et
peut pendre le décodeur** — le md5 est un garde-fou, pas une formalité.

Licences : code GPL-2.0 ; ucode Amlogic « use with Amlogic chips, not as part of the
kernel » ; `monet.bin` sous licence Chips&Media. **Ne pas committer les blobs dans le
dépôt public** ; les traiter comme du firmware non redistribuable (`requireFile` ou
paquet séparé) tant que la licence n'est pas tranchée.

## 2. État de l'existant dans `nixelec-meson64`

- `nixelec.vpu.mode` vaut **`stateless`** par défaut : `meson-amvdec` + série
  amlogic-0118..0128 ; décodage qualifié bit-exact, Kodi DRMPRIME OK.
- Le mode `stateful` existe (staging `meson-vdec`) mais n'est pas le mode qualifié.
- **Aucun encodeur** : `CONFIG_VIDEO_MESON_VDEC=m`, pas de module venc.
- Le pruning de modules est **deny-by-default** (`prune_modules.py`, socle + alias `of:`
  + `extraKeep`) : un module non listé est silencieusement absent (précédent B1, WiFi
  QCA9377).
- Le firmware de famille passe par `modules/system/vdec-firmware.nix` et
  `hardware.firmware`.

## 3. Design d'intégration proposé

### 3.1 Venc-only d'abord (recommandé)

Ne pas toucher au décodeur qualifié. N'ajouter que les encodeurs :

- `pkgs/meson-sm1-codecs.nix` : dérivation noyau
  (`make -C ${kernel.dev}/lib/modules/${kernel.modVersion}/build M=<dir> modules`),
  `KDIR` pointé sur `kernel.dev`, installation dans
  `$out/lib/modules/${modVersion}/updates/`, CLI `venc` dans `$out/bin`.
  Construire contre `config.boot.kernelPackages.kernel` (le noyau nixbian de la carte),
  pas le noyau nixpkgs par défaut.
- `boot.extraModulePackages = [ pkgs.meson-sm1-codecs ]` ;
  `boot.kernelModules = [ "amvenc_avc" "meson-venc-h264" "amvenc_hevc" "meson-venc-hevc" ]`.
- `pkgs/meson-sm1-firmware.nix` : remplacer `get-firmware.py` (réseau interdit en
  sandbox) par des `fetchurl` pinnés + `hardware.firmware`.
- CMA : `boot.kernelParams = [ "cma=512M" ]` si 4K (le README : 256 Mo suffit pour un
  encode 4K HEVC avec `-num_output_buffers 6` ; 512 Mo pour décode+encode 4K).
- Permissions : `/dev/video*` groupe `video`, l'utilisateur du service NVR/kiosque
  doit y être.
- **Pruning** : ajouter les quatre modules à l'allowlist, puis vérifier `modinfo` et
  `modules.order` **après** build — ne pas se fier au `modules.order` recopié (leçon B1).
- Udev/chargement : `boot.kernelModules` suffit ; pas de `/etc/modules` à la main.

### 3.2 Si le `vdec` SM1 est retenu

- Il **remplace** le `meson-vdec` stateful (même nom, `updates/` prioritaire), mais
  notre stack est **stateless** (`meson-amvdec`) : ne pas empiler les deux.
- Deux choix, à trancher sur une cible SM1 :
  - garder `meson-amvdec` (stateless) et ne prendre que les encodeurs ;
  - passer la cible en `stateful` + le `vdec` du projet, et re-qualifier le décodage.
- Si le `vdec` est retenu, préférer un `series.conf` dans `nixbian` (opt-in plateforme)
  à un module hors arbre qui shadow le built-in : le staging est un patch, pas un simple
  `.ko`, et il doit suivre les bumps de noyau.
- Sur GXL (N5), le `vdec` SM1 n'apporte rien : ne pas l'intégrer.

### 3.3 Version de noyau

Testé **6.18.55-ophub** ; notre edge est **7.0.14**. Le compat layer (vb2, v4l2-m2m,
APIs staging) peut casser. Le projet se compile contre les headers du noyau courant
(`KDIR`), donc la dérivation Nix est simple ; c'est la **compatibilité API** qui est le
risque. Faire le spike sur une box SM1 avant tout commit dans `nixelec-meson64`.

## 4. Gates

**P0 — build**
- `nix build .#meson-sm1-codecs` (cross aarch64) vert ;
- `modinfo` des quatre modules ; `boot.extraModulePackages` les installe ;
- le pruning ne les jette pas.

**P1 — fonction**
- `v4l2-ctl --list-devices` montre `meson-venc-h264` (et `-hevc`) ;
- `v4l2-ctl -d /dev/videoN --list-formats-out` liste H264 (et HEVC) en capture ;
- `ffmpeg -f rawvideo -pix_fmt nv12 ... -c:v h264_v4l2m2m -b:v 6M` produit un flux
  lisible ; viser ~58 fps en 1080p (référence auteur) ;
- transcode GStreamer zéro-copie `v4l2h264dec ! v4l2h265enc` (si HEVC) ;
- décodage existant **non régressé** (tests bit-exact) ; Kodi OK ;
- reboot : modules chargés, devices présents (pas d'état de session).

**P2 — NVR**
- un flux 1080p H.264 encodé à < 1 cœur ; CPU/thermique ;
- 4K si besoin : CMA 512 Mo, `-num_output_buffers 6` ;
- l'encode ne bloque pas le décode (un job à la fois sur le VE) → mesurer le pipeline
  complet.

## 5. Risques et critères d'abandon

- **100 % AI-generated** (hors vendor/upstream), pas upstream, **une seule carte**
  testée, noyau 6.18 vs 7.0.14 : revue de provenance et de qualité obligatoire.
- **Firmware** : ucode lié à une version ; un mauvais ucode peut pendre le décodeur.
  Blobs hors dépôt public, md5 pinnés.
- **Licences** : GPL-2.0 pour le code, termes Amlogic pour l'ucode, Chips&Media pour
  `monet.bin` → pas de redistribution dans `nixelec-meson64` public sans vérification.
- **Décode H.264** : une session à la fois ; deblocking désactivé → quelques lignes
  fausses en bas de macrobloc (limite du driver).
- **HEVC** : WAVE420L, probablement absent sur GXL ; 4K encode ~11 fps → pas de 4K
  temps réel.
- **RC H.264** frame-level ; les contrôles prennent effet au prochain stream.
- **Abandon** si : pas de build sur 7.0.14 en 1 j ; pas de 1080p30 à < 1 cœur ;
  régression du décodage ; hang du décodeur.

## 6. Décision proposée

1. **Ne pas intégrer sur la N5 (GXL)** — hors périmètre du driver.
2. **Spike sur une cible SM1** (S905X3 : HK1 X3 ou équivalent d'occasion), hors dépôt :
   build contre 7.0.14, encode 1080p, qualité, CPU. Compter 1–2 j.
3. Si spike vert : `venc-only` dans `nixelec-meson64`, derrière une option
   `nixelec.codecs.sm1.enable` (défaut `false`), firmware séparé, pruning, gates ;
   puis hôte HavenOS.
4. Si l'objectif est le NVR : le driver n'est utile que pour un **transcode** ; le NVR
   vit sur **remux + substreams**. Ne pas conditionner le NVR à cette intégration.

## 7. Questions ouvertes

- Quelle cible SM1 (achat, prêt, ou abandon) ?
- HEVC encode nécessaire, ou H.264 suffit ?
- La N5 reste-t-elle la cible Amlogic (GXL, sans encode), ou passe-t-elle en simple
  client ?
- Budget : une box SM1 + 1–2 j de spike.
