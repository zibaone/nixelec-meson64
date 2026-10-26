# Étude — `nixelec-meson64`

> **Statut** : étude + bring-up ; flake et module N5 initialisés, boot
> LibreELEC mesuré, aucune image nixbian bootée.
> **Date** : 2026-10-25 (mesures N5 : 2026-10-26).
> **Objet** : décider entre `meson` et `meson64`, délimiter le périmètre
> S905L/S905X / S905X4, et lister le gap entre ce que fournit `nixbian` et une
> appliance réellement fonctionnelle (VPU, WiFi, audio, CEC, HDMI, GPU, boot).

---

## 1. Décision de nommage

Créer **`nixelec-meson64`**, pas `nixelec-meson`.

- La décision est déjà actée dans
  `havenos-workspace/wiki/decisions/nixelec-sunxi64-naming.md` et rappelée dans
  `nixelec-sunxi64/README.md` : la couche publique est organisée par **famille
  SoC**, pas par carte.
- Dans `nixbian`, `meson` est le famille **ARM32** (S805/S812). Elle ne contient
  que trois cartes (`aml-s805-mxq`, `odroidc1`, `onecloud`) et un noyau 6.12
  armhf. Ce n'est pas la famille du S905L/S905X.
- `meson64` est la famille **ARM64** : GXBB, GXL, GXM, AXG, G12A, G12B, SM1.
  C'est elle qui couvre le S905L, S905X, S905X2, S905X3, S905D, S912, A311D
  et S922X.

Le nom public suit donc le nom de famille `nixbian` : `nixelec-meson64`.
Un nom commercial éventuel (`nixelec-meson`) ne doit pas devenir le nom du
dépôt : il masquerait la distinction 32/64 bits qui est justement la source de
l'erreur.

---

## 2. Périmètre SoC

| SoC | Génération | Famille mainline | Statut dans `nixbian` | Décision pour `nixelec-meson64` |
|---|---|---|---|---|
| **S905L (mesuré sur N5)** / S905X / S905D / S905W | GXL | `meson64` | noyau + quelques cartes, DTB très incomplet | **référence initiale** |
| S905X2 | G12A | `meson64` | noyau, DTB incomplet | phase 2 |
| S905X3 | SM1 | `meson64` | noyau, DTB incomplet | phase 2 |
| A311D / S922X | G12B | `meson64` | noyau, DTB incomplet | phase 2 |
| S905X4 | SC2 | aucune DTS mainline | aucune carte, aucune famille | **hors périmètre** |
| S905Y4 | S4 | DTS mainline partielle | `meson-s4t7` vendor 5.15 | **hors périmètre initial** |
| A311D2 / VIM4 | T7 | aucune DTS mainline | `meson-s4t7` vendor 5.15 | **hors périmètre initial** |

### Pourquoi le S905X4 n'est pas dans `meson64`

Le S905X4 appartient à la génération **SC2**. Il n'est ni S4 (S905Y4), ni T7
(A311D2), ni meson64. Constat vérifié sur les sources noyau et U-Boot utilisées
par `nixbian` :

- noyau `linux-7.0.14` : `arch/arm64/boot/dts/amlogic` contient les DTS S4
  (`meson-s4.dtsi`, `meson-s4-s905y4-khadas-vim1s.dts`,
  `meson-s4-s805x2-aq222.dts`) mais **aucun DTS SC2 / S905X4** ;
- `meson-s4.dtsi` ne contient **ni VPU, ni HDMI, ni GPU, ni audio, ni CEC** :
  c'est une base essentiellement headless (CPU, clocks, pinctrl, SD/eMMC,
  Ethernet, UART) ;
- U-Boot `2025.04` n'a **aucun defconfig S4 ni SC2** ;
- `nixbian` n'a **aucune carte SC2** ; `meson-s4t7` ne contient que
  `khadas-vim1s` et `khadas-vim4`, en noyau Khadas 5.15 et U-Boot CoreELEC
  2019.01 signé.

Le S905X4 est donc un **projet vendeur séparé**, pas une extension de
`nixelec-meson64`. Il faut le traiter après, avec un noyau BSP SC2 et une
chaîne de boot propre, ou attendre un support mainline.

---

## 3. Ce que `nixbian` fournit

### 3.1 Plateformes

`metadata/nix/families/meson64/platforms.nix` :

- `meson64-current` : noyau stable 6.18.y, config Armbian complète ;
- `meson64-edge` : noyau 7.0.y, config Armbian complète ;
- 29 cartes × 2 branches, kernel/DTB/U-Boot/firmware mutualisés par famille.

Le mode `armbian` applique le `.config` Armbian complet. C'est le tier à utiliser
pour une appliance, pas le mode `defconfig`.

### 3.2 Briques noyau présentes

Vérifié dans `metadata/nix/families/meson64/configs/linux-meson64-current.config`
(les symboles sont identiques ou équivalents dans `edge`) :

| Besoin | Symbole | Ligne |
|---|---|---|
| Affichage | `CONFIG_DRM_MESON=y` | 2494 |
| GPU GXL (Mali-450) | `CONFIG_DRM_LIMA=m` | 2506 |
| GPU G12/SM1 (Mali-G31) | `CONFIG_DRM_PANFROST=m` | 2507 |
| Décodeur vidéo | `CONFIG_VIDEO_MESON_VDEC=m` | 3319 |
| Audio analogique/HDMI | `CONFIG_SND_MESON_GX_SOUND_CARD=m`, `CONFIG_SND_MESON_AXG_SOUND_CARD=m` | 2598-2599 |
| Audio HDMI | `CONFIG_DRM_DW_HDMI_I2S_AUDIO=m` | 2489 |
| CEC | `CONFIG_CEC_MESON_AO=m`, `CONFIG_CEC_MESON_G12A_AO=m` | 2123-2124 |
| WiFi Broadcom | `CONFIG_BRCMFMAC=m` | 1061 |
| WiFi Realtek | `CONFIG_RTW88_8822CS=m`, `CONFIG_RTL8822CS=m`, `CONFIG_RTL8189FS=m`, etc. | 1110-1135 |
| BT | `CONFIG_BT_HCIUART_BCM=y`, `CONFIG_BT_HCIUART_RTL=y` | 567-568 |
| MMC | `CONFIG_MMC_MESON_GX=y` | 3130 |
| IR | `CONFIG_IR_MESON=m` | 2107 |

Les patches Armbian meson64 ajoutent notamment le HEVC au décodeur Meson, des
correctifs HDMI/audio (`general-meson-aiu-Fix-HDMI-codec-control-selection.patch`),
CEC, Panfrost, et des correctifs DTS par carte.

Les firmwares VPU (`meson/vdec/*.bin`) sont déjà fournis par `linux-firmware`
dans nixpkgs ; ils sont présents localement, compressés en `.zst`.

### 3.3 Couverture cartes réelle

Le dépôt contient 29 cartes meson64 (Le Potato, Radxa Zero/Zero2, Odroid
C2/C4/N2/HC4, Khadas VIM1/2/3/3L, Banana Pi M5/M2S/CM4, Libretech A311D,
aml-s9xx-box, etc.).

Mais **seules deux cartes ont un DTB dans les métadonnées** :

- `aml-a311d-cc` → `amlogic/meson-g12b-a311d-libretech-cc.dtb` ;
- `aml-s905d3-cc` → `amlogic/meson-sm1-s905d3-libretech-cc.dtb`.

Toutes les autres ont `dtb = null`, y compris Le Potato, Radxa Zero, Radxa
Zero 2, Odroid N2/C4, Khadas VIM1/2/3, Banana Pi M5/M2S.

Conséquence : `platformDtbs`
(`metadata/nix/families/meson64/package.nix`) ne construit que ces **deux DTBs**
pour la famille. Les autres cartes n'ont pas de DTB dans le noyau produit.

Mesure du 2026-10-26 : le DTB `amlogic/meson-gxl-s905x-p212.dtb` existe dans
le noyau et boote la N5 S905L, mais `nixbian` ne le produit pas car
`aml-s9xx-box` a `dtb = null`. Il faut une table carte → DTB explicite ou un
profil N5 avec `dtb = "amlogic/meson-gxl-s905x-p212.dtb"`.

---

## 4. Gap vers une appliance fonctionnelle

### 4.1 DTB — bloquant n°1

Cause : l'extracteur ne lit que `BOOT_FDT_FILE`
(`src/armbian_extractor/core.py:498`). La plupart des configs Armbian meson64 ne
définissent pas cette variable. Exemple : `config/boards/lepotato.conf` n'a
aucun `BOOT_FDT_FILE`, alors que le DTB existe dans le noyau
(`amlogic/meson-gxl-s905x-libretech-cc.dtb`).

Il faut, dans `nixbian` :

- soit une table carte → DTB explicite ;
- soit un fallback `BOOT_FDT_FILE` → `DEFAULT_DEVICE_TREE` avec vérification ;
- soit, pour les cartes à DTB multiples, une liste de DTBs à construire au lieu
  d'un DTB unique.

Sans cette étape, `hardware.deviceTree.name` retombe sur
`boardData.kernel.config` (`nix/parts/nixos-module.nix:468`) et l'image ne peut
pas sélectionner le bon DTB.

### 4.2 U-Boot — bloquant n°2

`nixbian` construit U-Boot avec `metadata/nix/library.nix:500`, mais :

- il n'exécute pas le post-traitement FIP Amlogic
  (`aml_encrypt_gxl`, `build-fip.sh`, blobs `amlogic-boot-fip`) ;
- il n'installe pas `u-boot.bin.sd.bin` ;
- pour les cartes `config = "none"`, il produit une dérivation `uboot-none`,
  pas un bootloader utilisable ;
- la liste `filesToInstall` retombe sur l'union Sunxi/Rockchip/StarFive
  (`u-boot-sunxi-with-spl.bin`, `u-boot.itb`, etc.), ce qui ne correspond pas
  aux artefacts Meson.

Or U-Boot amont documente le schéma Amlogic suivant
(`doc/board/amlogic/libretech-cc.rst`, `aml-a311d-cc.rst`) :

```sh
dd if=fip/u-boot.bin.sd.bin of=$DEV conv=fsync,notrunc bs=512 skip=1 seek=1
dd if=fip/u-boot.bin.sd.bin of=$DEV conv=fsync,notrunc bs=1 count=440
```

Le fichier bootable est `u-boot.bin.sd.bin`, produit par le FIP externe. Ce
n'est pas `u-boot.bin` brut.

`HavenOS/images/sd-image-amlogic.nix:78` écrit seulement `u-boot.bin` à l'offset
512, sans les 440 premiers octets. Ce n'est pas le schéma Armbian
(`meson64_common.inc` écrit 442 octets à l'offset 0 puis le reste au secteur 1).

Il faut donc, dans `nixbian` :

- vendre ou fetcher `LibreELEC/amlogic-boot-fip` ;
- exécuter le post-traitement par carte/famille ;
- installer `u-boot.bin.sd.bin` et les fichiers DTB/U-Boot utiles ;
- exposer un module d'image qui écrit les 440/442 octets + le secteur 1.

Tant que ce n'est pas fait, aucune image meson64 n'est prouvée bootable avec
le schéma FIP.

Sur la N5, le vendor U-Boot **2015.01** déjà présent en eMMC boote une carte
SD via `s905_autoscript` + `uEnv.ini` + DTB p212 (mesuré le 2026-10-26 avec
LibreELEC). C'est la méthode de bring-up à utiliser avant de packager le FIP.
La variante `u-boot.ext` (U-Boot mainline chargé par le vendor) reste à
tester.

### 4.3 Boîtes TV génériques

`aml-s9xx-box` n'est pas une cible turnkey :

- `dtb = null` ;
- U-Boot préconstruit `packages/blobs/meson/u-boot-vim2-sd.bin` ;
- extlinux Armbian pointe par défaut sur
  `amlogic/meson-gxl-s905w-tx3-mini.dtb` ;
- chaque boîte a son DTB, son WiFi (AP6xxx, RTL8822, etc.), sa télécommande et
  parfois son layout eMMC.

Il faut un profil « boîte TV » avec DTB **explicite** et firmware **explicite**,
pas une image universelle. C'est acceptable en phase 2, après une carte de
référence.

### 4.4 Firmware WiFi/BT

`metadata/nix/firmware.nix` copie pour meson64 les répertoires `meson64`,
`meson` et `bt`. Il ne copie **ni `brcm`, ni `rtlwifi`, ni `rtl_bt`**, ni les
NVRAM/calibrations spécifiques (`brcmfmac-ap6330-sdio.txt`,
`brcmfmac-ap6255-sdio.txt`, etc.).

`linux-firmware` couvre une partie des binaires, mais pas toutes les
calibrations carte. Il faut :

- inclure `brcm`, `rtlwifi`, `rtl_bt` dans le firmware de famille ;
- ajouter les fichiers NVRAM par carte ;
- exposer un module WiFi générique (wpa_supplicant/iwd) réutilisable, distinct
  du module UWE5622 de sunxi64.

### 4.5 VPU — état au 2026-10-25

**Décision** : chemin **stateless** (backport 7.0 de `meson-amvdec` +
`nix-v4l2-request`). Voir
[`decision-vpu-stateless.md`](decision-vpu-stateless.md).

Le paysage a changé depuis la première rédaction. Détail complet dans
[`vpu-etat-de-lart-2026-10-25.md`](vpu-etat-de-lart-2026-10-25.md).

En résumé :

- le driver **upstream** `meson-vdec` reste **stateful**, sans HEVC, 10-bit ni
  AFBC. Le chemin Kodi passe par FFmpeg `v4l2_m2m` + DRM PRIME patché
  (LibreELEC), validé sur S905X/GXL par Michael Freidkin ; le fix de taille
  des plans est mergé après 7.3 (7.4) ;
- LibreELEC master porte une **réécriture stateless** `meson-amvdec`
  (pile Amlogic de 210 patchs, dont ~15 pour le VPU ; GXBB/GXL/GXLX/GXM/
  G12A/G12B/SM1 + S4, H.264/HEVC/MPEG-2/VP9, 10-bit, AFBC, déinterlaceur).
  Elle n'est **pas upstream**, mais c'est la voie la plus complète et elle est
  destinée à `nix-v4l2-request` ;
- Amlogic pousse un driver stateless **S4** (série v12, 2026-10-22) avec
  firmware signé/TEE, H.264 8-bit progressif seulement, non mergé ;
- **S905X4/SC2** n'a toujours aucun driver mainline ; les firmwares AV1/HEVC
  existent, pas le code.

**Décision du 2026-10-25 : chemin stateless retenu.**

- noyau `nixbian` meson64 **7.0** + sous-ensemble vdec `amlogic-0118` à
  `0128` (driver `meson-amvdec`) ;
- `CONFIG_VIDEO_MESON_VDEC=n` et `CONFIG_VIDEO_MESON_AMVDEC=m` ;
- firmwares `meson/vdec/*_multi.bin` à packager ;
- userspace `nix-v4l2-request` : H.264 d'abord, HEVC après rebase FFmpeg
  pour `EXT_SPS_ST_RPS`/`LT_RPS` ;
- le chemin stateful `v4l2_m2m` + `v4l2-drmprime` reste une solution de repli,
  pas la cible.

Plan et gates : [`decision-vpu-stateless.md`](decision-vpu-stateless.md).
Patchs prêts : `patches/kernel/meson64-vdec-7.0/`.

C'est toujours le point **go/no-go** d'un vrai NixELEC sur Meson, mais il est
désormais documenté et daté.

### 4.6 Audio et CEC

Les drivers sont présents, mais :

- `dw-hdmi-i2s-audio` et `snd-soc-hdmi-codec` n'ont pas de compatible OF et
  peuvent être supprimés par l'élagage DTB de `nixbian`. Il faut les ajouter à
  `boot.kernelModules`, comme le fait `nixelec-sunxi64` ;
- garder `meson-vdec`, `meson-drm`, `snd-soc-meson-gx`,
  `cec-meson-ao`/`cec-meson-g12a-ao`, `lima`, `panfrost` dans l'allowlist
  d'élagage ;
- le service de reprobe CEC de sunxi64 est spécifique `dw-hdmi-cec` ; Meson
  utilise `cec-meson-ao` / `cec-meson-g12a-ao`. Il faut un service Meson ou
  désactiver le reprobe ;
- la config meson64 est à `CONFIG_CMA_SIZE_MBYTES=128`. La 4K et le VPU peuvent
  demander plus ; à mesurer carte par carte (`cma=256M` par exemple).

### 4.7 Récapitulatif des gaps

| Domaine | État noyau | État nixbian | Gap principal |
|---|---|---|---|
| Display / GPU | prêt (DRM, Lima/Panfrost) | DTB manquant | construire les DTBs |
| HDMI audio | prêt | modules élaguables | allowlist + test |
| Analog audio / SPDIF | prêt | dépend du DTS | DTB + test |
| CEC | prêt | service sunxi inadapté | service Meson |
| VPU | stateless LibreELEC (`amvdec`) | backport 7.0 compilé, à intégrer | firmware + FFmpeg + validation |
| WiFi / BT | pilotes prêts | firmware incomplet | NVRAM/carte |
| Boot | U-Boot amont + FIP | FIP absent | post-traitement + `u-boot.bin.sd.bin` |
| S905X4 | non | non | projet séparé |

---

## 5. Architecture cible de `nixelec-meson64`

Reprendre la structure de `nixelec-sunxi64`, en remplaçant le spécifique
Allwinner par le spécifique Meson.

```text
nixelec-meson64/
├── flake.nix
├── parts/
│   ├── modules.nix
│   ├── configurations.nix
│   ├── packages.nix
│   └── checks.nix
├── modules/
│   ├── family/meson64.nix
│   ├── boards/
│   │   ├── lepotato.nix
│   │   ├── radxa-zero2.nix
│   │   └── ...
│   ├── profiles/kodi-gbm.nix
│   ├── image/meson-sd.nix
│   └── services/wifi-brcm.nix
└── docs/
```

### 5.1 Famille

`modules/family/meson64.nix` doit gérer :

- `nixelec.kernelPackage` : noyau de famille
  `nixbian.legacyPackages.<system>.meson64.kernels.meson64-<vendor>` ;
- `hardware.nixbian.family = "meson64"`, `configMode = "armbian"` ;
- `boot.kernelParams` : `console=ttyAML0,115200n8`, CMA, éventuel
  `video=HDMI-A-1:...` ;
- `boot.initrd.availableKernelModules` : `mmc_block`, `meson-gx-mmc` (ou le nom
  exact du module MMC dans la config), `ext4`, `vfat` ;
- `boot.kernelModules` : `dw-hdmi-i2s-audio`, `snd-soc-hdmi-codec`,
  `cec-meson-ao`/`cec-meson-g12a-ao` ;
- `hardware.graphics.enable = true` (Mesa Lima/Panfrost) ;
- `boot.initrd.includeDefaultModules = false` si la liste générique NixOS
  contient des modules absents du noyau Armbian ;
- `boot.loader.generic-extlinux-compatible.configurationLimit = 0` pour un
  kiosque.

### 5.2 Image SD Meson

`modules/image/meson-sd.nix` doit reproduire le schéma Armbian/U-Boot :

- table de partitions commençant à 4 MiB (8192 secteurs) pour laisser la place
  au bootloader ;
- U-Boot : `dd` de `u-boot.bin.sd.bin` à l'offset 0 (440/442 octets) puis au
  secteur 1 (`bs=512 skip=1 seek=1`) ;
- partition boot FAT ou ext4 avec `extlinux.conf`, `Image`, `initrd`, `dtbs/` ;
- partition racine ext4 ;
- `image.fileName = "nixelec-meson64-<board>.img"` ;
- vérifier le DTB effectivement présent dans `/boot/dtbs/`.

Le module `HavenOS/images/sd-image-amlogic.nix` est une base utile, mais il
n'écrit que `u-boot.bin` à 512 octets : il ne suffit pas.

### 5.3 Réutilisation depuis `nixelec-sunxi64`

À reprendre presque tel quel :

- `modules/profiles/kodi-gbm.nix` (service Kodi GBM, utilisateur, PipeWire,
  réglages, CEC) ;
- `parts/checks.nix` (éval, formatage, politique de redémarrage Kodi) ;
- le schéma `nixelec.kernelPackage` et le module de famille.

À adapter :

- le module image (offset U-Boot, layout Amlogic) ;
- le service CEC (pas `dw-hdmi-cec`) ;
- le WiFi (pas UWE5622) ;
- les modules noyau à conserver.

À ne pas réutiliser :

- `uwe5622`, `uwe5622-firmware`, `wifi-uwe5622` ;
- `sunxi-sd.nix` tel quel.

### 5.4 Kodi et VPU

Deux configurations doivent rester séparées :

- **affichage/GPU** : Kodi GBM avec Mesa Panfrost/Lima, indépendant du VPU ;
- **décodage matériel** : à prouver séparément. Tant que la chaîne n'est pas
  validée, la configuration par défaut doit être explicitement « software
  decode » ou ne pas activer `useprimedecoder`.

**Décision : pile stateless.**

| Pile | Noyau | Userspace | Statut |
|---|---|---|---|
| **stateless** | `meson-amvdec` backport 7.0 + staging désactivé | `nix-v4l2-request` (FFmpeg Request + Kodi) | **retenu** |
| stateful | `meson-vdec` 7.0 + patches Armbian | FFmpeg `v4l2-drmprime` + Kodi | repli |

`nix-v4l2-request` n'est **pas** la pile du driver stateful : ne pas utiliser
`h264_v4l2request`/`hevc_v4l2request` avec `meson-vdec`. Le chemin retenu est
le driver stateless `amvdec`. Détail :
[`decision-vpu-stateless.md`](decision-vpu-stateless.md).

---

## 6. Plan par phases

### Phase 0 — débloquer `nixbian`

1. Table DTB meson64 (au moins Le Potato, Radxa Zero 2, Banana Pi M5,
   Odroid N2/C4, Khadas VIM3).
2. U-Boot Meson : FIP + `u-boot.bin.sd.bin` + installation correcte.
3. Firmware : `brcm`, `rtlwifi`, `rtl_bt` + NVRAM par carte.
4. Gate DTB : vérifier que le DTB contient les nœuds `vpu`, `hdmi`, `gpu`,
   `cec`, `sound`.

### Phase 1 — `nixelec-meson64` minimal

- Carte de référence **GXL** : **Magicsee N5 mesuré S905L** (pas S905X). Voir
  [`boards/magicsee-n5.md`](boards/magicsee-n5.md) ; le nom N5 couvre aussi
  S905X2/S905X3/S905X4 selon le modèle, mais ce n'est pas le cas ici.
  Le DTB p212 boote, mais le Bluetooth QCA9377 et le HDMI restent à qualifier.
- D'abord qualifier la boîte : SoC exact, DTB, WiFi/BT, Ethernet, IR, boot SD.
- Image SD bootable, cold boot, HDMI, audio HDMI, CEC, clavier/télécommande.
- Checks : éval, formatage, présence des modules, présence du DTB dans l'image.

Le **Vontar X4** est un S905X4/SC2 : hors périmètre, voir
[`boards/vontar-x4.md`](boards/vontar-x4.md).

### Phase 2 — G12/SM1

- Radxa Zero 2 (A311D, Panfrost, WiFi/BT) ou Banana Pi M5.
- Ajouter le module WiFi/BT et les NVRAM correspondants.
- Vérifier le GPU Panfrost et l'audio.

### Phase 3 — VPU stateless (décidé)

Lire [`decision-vpu-stateless.md`](decision-vpu-stateless.md) et
[`vpu-etat-de-lart-2026-10-25.md`](vpu-etat-de-lart-2026-10-25.md).

- intégrer `patches/kernel/meson64-vdec-7.0/` au noyau meson64 7.0 ;
- désactiver le staging (`CONFIG_VIDEO_MESON_VDEC=n`) et activer
  `CONFIG_VIDEO_MESON_AMVDEC=m` ;
- packager les firmwares `*_multi.bin` / `*_mmu.bin` ;
- prototyper **H.264** d'abord : `v4l2-ctl --list-formats-out` doit exposer
  `H264_SLICE`, puis `h264_v4l2request` et Kodi ;
- comparer MD5/PSNR au décodage logiciel et mesurer la charge CPU ;
- HEVC/VP9 ensuite, après rebase FFmpeg pour les contrôles RPS étendus ;
- décision explicite : hardware decode supporté, ou software-only documenté.

### Phase 4 — boîtes TV GXL (S905L/S905X)

- Profil explicite par boîte : DTB, WiFi, télécommande, layout eMMC.
- Ne pas promettre une image unique pour toutes les boîtes.

### Hors périmètre

- S905X4/SC2 (aucun driver mainline ; firmware seul) ;
- T7/VIM4 (vendor) ;
- décodage AV1 matériel.

S4/S905Y4 n'est plus un simple « non » : deux drivers stateless non mergés
existent (LibreELEC `amvdec` et Amlogic v12). À surveiller, sans l'inclure
dans la première release.

---

## 7. Gates d'acceptation

Une carte n'est « supportée » que si les preuves suivantes existent :

- [ ] `nix build` de l'image réussit ;
- [ ] l'image contient le bon DTB et `u-boot.bin.sd.bin` est écrit aux bons
      offsets ;
- [ ] cold boot depuis SD, sans intervention ;
- [ ] `/dev/dri/card0` et `renderD128` présents, Kodi GBM démarre ;
- [ ] HDMI vidéo + audio (test de son) ;
- [ ] CEC (si la carte le expose) ;
- [ ] WiFi/BT (si la carte en a) ;
- [ ] `dmesg` sans erreur bloquante ;
- [ ] VPU : soit validé, soit explicitement documenté comme non supporté.

---

## 8. Risques et non-objectifs

- **Risque principal** : croire que « le driver existe » signifie « Kodi
  décode ». Le driver stateless `amvdec` n'est pas upstream, vient d'une pile
  Amlogic assistée par IA, et aucun test matériel n'a encore été fait. C'est
  le risque qui peut invalider la promesse NixELEC.
- **Risque U-Boot** : le FIP Amlogic n'est pas dans `nixbian` aujourd'hui. Sans
  lui, l'image ne boote pas, même avec un noyau et un DTB corrects.
- **Risque DTB** : 27 cartes sur 29 n'ont pas de DTB dans les métadonnées. Un
  build « vert » ne prouve pas que la carte boote.
- **Non-objectif** : supporter le S905X4 dans cette première phase.
- **Non-objectif** : remplacer LibreELEC/CoreELEC pour le décodage vendeur.
  `nixelec-meson64` vise le mainline, avec ses limites documentées.

---

## 9. Références

- `nixbian/metadata/nix/families/meson64/platforms.nix`
- `nixbian/metadata/nix/families/meson64/package.nix`
- `nixbian/metadata/nix/families/meson64/configs/linux-meson64-current.config`
- `nixbian/metadata/nix/families/meson64/configs/linux-meson64-edge.config`
- `nixbian/metadata/board_metadata.json`
- `nixbian/src/armbian_extractor/core.py:498`
- `nixbian/metadata/nix/library.nix:500`
- `nixbian/nix/parts/nixos-module.nix:437-468`
- `nixbian/metadata/nix/firmware.nix`
- `nixelec-sunxi64/modules/family/sunxi64.nix`
- `nixelec-sunxi64/modules/image/sunxi-sd.nix`
- `nixelec-sunxi64/modules/profiles/kodi-gbm.nix`
- `nix-v4l2-request/README.md`
- [`vpu-etat-de-lart-2026-10-25.md`](vpu-etat-de-lart-2026-10-25.md)
- [`decision-vpu-stateless.md`](decision-vpu-stateless.md)
- [`boards/magicsee-n5.md`](boards/magicsee-n5.md)
- [`boards/vontar-x4.md`](boards/vontar-x4.md)
- [`branches.md`](branches.md)
- `patches/kernel/meson64-vdec-7.0/`
- `HavenOS/images/sd-image-amlogic.nix`
- U-Boot `doc/board/amlogic/libretech-cc.rst`, `aml-a311d-cc.rst`
- Armbian `config/sources/families/include/meson64_common.inc`
- `havenos-workspace/wiki/decisions/nixelec-sunxi64-naming.md`
