# Magicsee N5 — bring-up

> **Statut** : boot SD mesuré le 2026-10-26 (LibreELEC 6.14.2, UART).
> **Famille** : GXL / `meson64`.
> **SoC mesuré** : **S905L**, pas S905X. La mesure corrige l'hypothèse initiale.

## Identification mesurée

Relevé sur la boîte d'origine, UART `ttyAML0` à 115200 8N1 :

| Élément | Valeur mesurée |
|---|---|
| Modèle commercial | Magicsee N5 (modèle d'origine) |
| SoC | Amlogic **GXL S905L** |
| `soc_id` | `0x21` (GXL), package `S905L` (`pack 0xc0`) |
| Révision | `21:d - c4:2` |
| CPU | 4 × Cortex-A53 r0p4, 1,2 GHz |
| RAM | **2 GiB** (DDR3 792 MHz, 16-bit, `Rank0 2048MB-2T-11`) |
| eMMC | Samsung **MAG2GC**, 15 634 268 160 octets = **14,56 GiB** (classe 16 Go), HS200 |
| SD | carte de test 29,2 GiB (classe 32 Go), LibreELEC |
| Ethernet | `meson8b-dwmac`, PHY interne GXL, RMII |
| WiFi | **QCA9377**, `ath10k_sdio`, SDIO `0271:0701` |
| Bluetooth | QCA9377 combo, mais **mal bindé par le DTB p212** (voir plus bas) |
| IR | `meson-ir`, décodeur NEC, `event0` |
| CEC | `meson-ao-cec`, `/dev/cec0` |
| GPU | Lima Mali-450, `/dev/dri/card1`, `renderD128` |
| Display | `meson-drm`, `/dev/dri/card0` |
| Audio | `gx-sound-card`, carte 0 `S905X-P212` |
| USB | xHCI (root hub) + dwc2 OTG ; aucun périphérique testé |
| VPU actuel | `meson_vdec` **stateful** (LibreELEC 6.14.2), pas notre cible |
| UART | `ttyAML0`, 115200 8N1 |

Détails utiles :

- eMMC : CID `1501004d414732474305dad9bab64100`, fabricant `0x15`,
  produit `MAG2GC`, date `04/2014`, boot0/boot1 et RPMB de 4 MiB chacun.
- WiFi : firmware `WLAN.TF.1.1.1-00061-QCATFSWPZ-1 api 5` ; le fichier
  `ath10k/QCA9377/hw1.0/board-2.bin` spécifique manque et le driver utilise
  le fallback. `wlan0`/`wlan1` partagent la MAC `94:e0:d6:02:99:xx`.
- Bluetooth : le DTB p212 décrit un contrôleur Broadcom ; le kernel tente
  `hci_uart_bcm` et échoue (`Failed to set baudrate`). Le matériel est un
  QCA9377 et doit utiliser `btqca`/un nœud DT QCA.
- IR : `meson-ir` sur `c8100580.ir`, récepteur brut + keymap NEC.
- CEC : `meson-ao-cec`, adresse physique `f.f.f.f` car HDMI débranché.
- GPU : Lima probe, mais avertissement `_opp_set_regulators: no regulator
  (mali) found` (non bloquant).
- VPU : le noyau LibreELEC expose `/dev/video0` (`meson-video-decoder`) avec
  `H264`, `HEVC`, `VP90` en sortie et `NM12` en capture. C'est le driver
  **stateful**, donc **pas de `H264_SLICE`**. Il ne prouve pas le chemin
  stateless.

## eMMC et disposition actuelle

La eMMC fait **16 Go nominaux**, pas 32 Go : le kernel et `parted` rapportent
14,56 GiB (15,63 Go décimaux, `30535680` secteurs de 512 octets). Les 32 Go
vus par l'utilisateur sont la carte SD (29,2 GiB). La capacité est confirmée
par `parted` (`Disk /dev/mmcblk1: 14910MiB`) et par le CID de la puce, pas
seulement par la table de partitions.

Disposition actuelle (MBR) :

| Partition | Début | Taille | FS | Rôle |
|---|---|---|---|---|
| — | 0 | 668 MiB | — | bootloader vendor + environnement U-Boot |
| `mmcblk1p1` | 668 MiB | 488 MiB | FAT16 | `BOOT_EMMC` |
| `mmcblk1p2` | 1157 MiB | 13,43 GiB | ext4 | `ROOT_EMMC` |

Le premier **668 MiB** n'est pas une partition : il contient le bootloader
vendor (BL1/BL2/BL31/BL33) et l'environnement U-Boot à `0x27400000`
(environ 628 MiB). **Toute installation sur eMMC doit préserver cette zone**,
sinon la boîte ne démarre plus sans outil de récupération Amlogic.

Les logs vendor parlent de 11 partitions (`logo`, `recovery`, `system`, …) :
c'est la table décrite dans le DTB vendor, pas la table MBR réellement
présente aujourd'hui.

## Boot mesuré

Chaîne observée :

1. Boot ROM → BL1 GXL (`9ac50e`) → BL2 (2017) → BL31 (2017) → BL33, tous
   chargés depuis la **eMMC**.
2. U-Boot vendor **2015.01** (16 août 2018), DRAM 2 GiB.
3. Il lit `s905_autoscript` (823 octets) sur la carte SD.
4. Le script essaie `u-boot.ext` (absent), puis charge `KERNEL` (uImage
   legacy lzo) + `uEnv.ini` + `amlogic/meson-gxl-s905x-p212.dtb`, et fait
   `bootm`.
5. LibreELEC 6.14.2 démarre sur `ttyAML0`.

`uEnv.ini` contient le DTB p212 et les arguments de boot. Il n'y a **pas
d'extlinux** sur cette carte. Les fichiers `aml_autoscript`,
`emmc_autoscript`, `boot.scr` et `boot.ini` sont aussi présents.

Conséquence : le boot SD via vendor U-Boot est prouvé. Le boot d'une image
nixbian n'est **pas encore** prouvé ; il faut soit chainer un `u-boot.ext`
mainline, soit produire un script vendor qui charge `Image` + initrd + DTB.

## DTB retenu (provisoire)

`amlogic/meson-gxl-s905x-p212.dtb` est le DTB de travail :

- il boote ;
- il expose Ethernet, WiFi QCA9377, IR, CEC, GPU Lima et la carte son ;
- il n'expose **pas** le bouton reset (`gpio-keys` absent) ;
- son nœud Bluetooth est Broadcom, alors que le module est QCA9377 ;
- le HDMI était débranché lors des mesures (EDID 0), donc audio HDMI et CEC
  ne sont pas validés.

À comparer avec le même noyau et les mêmes relevés :

1. `amlogic/meson-gxl-s905x-nexbox-a95x.dtb`
2. `amlogic/meson-gxl-s905x-libretech-cc.dtb`
3. `amlogic/meson-gxl-s905x-khadas-vim.dtb`
4. `amlogic/meson-gxl-s905x-hwacom-amazetv.dtb`

Un DTB qui boote ne suffit pas. Le bon DTB doit garder Ethernet, WiFi, IR,
SD, eMMC, CEC, GPU et audio. Pour le Bluetooth QCA9377, prévoir un overlay
ou un DTS dérivé de p212 plutôt qu'un DTB d'une autre boîte.

## Points à mesurer ensuite

- [x] SoC exact : GXL S905L (`0x21`, `21:d`)
- [x] RAM : 2 GiB
- [x] eMMC : 16 Go classe, 14,56 GiB, MAG2GC
- [x] Boot SD via vendor U-Boot + `s905_autoscript`
- [x] DTB de travail : p212
- [x] Ethernet : driver + PHY interne (lien non testé)
- [x] WiFi : QCA9377, driver et firmware chargés
- [ ] Bluetooth : QCA9377 avec nœud DT correct
- [x] IR : `meson-ir` + NEC
- [ ] HDMI vidéo + audio HDMI (HDMI débranché)
- [ ] CEC avec un téléviseur branché
- [x] GPU Lima
- [ ] Bouton reset (absent du DTB p212)
- [ ] Périphérique USB
- [ ] VPU stateless : `/dev/video*` avec `H264_SLICE`, puis décodage H.264

## Conséquences pour le VPU

- H.264 est la cible sûre sur GXL/S905L.
- HEVC et VP9 sont annoncés par le driver stateful via le compatible GXL,
  mais **pas encore décodés** sur cette boîte. Ne pas les promettre avant
  mesure avec `meson-amvdec`.
- Le DTB p212 active le VPU (`vpu@d0100000`, compatible
  `amlogic,meson-gxl-vpu`) ; c'est une bonne base pour le nœud `vdec`.
- Le driver staging doit rester désactivé dans le noyau nixbian
  (`CONFIG_VIDEO_MESON_VDEC=n`) au profit de `meson-amvdec`.

## Installation eMMC

Contraintes :

- ne pas écrire à l'offset 0 : le bootloader vendor occupe les 668 premiers
  MiB ;
- garder `boot0`/`boot1` intacts ;
- sauvegarder les 668 MiB et les boot partitions avant toute écriture ;
- commencer la première partition à 668 MiB (ou après) et laisser le
  chargeur vendor chaîner l'image NixOS.

Disko est adapté pour décrire p1/p2 et le montage, mais **pas pour effacer
toute la eMMC**. La configuration doit fixer `start = "668M"` pour la
première partition, ou être appliquée uniquement aux partitions existantes.

Méthode recommandée pour la première installation :

1. construire une image SD « installateur » qui boote avec le vendor U-Boot
   (même chaîne `s905_autoscript` + p212 que LibreELEC) ;
2. y embarquer disko, `nixos-install` et la configuration cible ;
3. sauvegarder les 668 premiers MiB et `mmcblk1boot0/1` avant toute écriture ;
4. lancer disko sur `/dev/mmcblk1` avec une table commençant à 668 MiB,
   formater p1 en FAT et p2 en ext4, puis installer le système ;
5. écrire le chargeur/`s905_autoscript` dans p1 et garder le vendor U-Boot.

Pour le boot, deux pistes à tester sur la N5 :

- **A** : placer un U-Boot mainline en `u-boot.ext` dans la FAT ; le
  `s905_autoscript` vendor le charge déjà et tente `go 0x1000000`. U-Boot
  mainline lit ensuite `extlinux.conf` (schéma NixOS standard) ;
- **B** : garder uniquement le vendor U-Boot et écrire un `s905_autoscript`
  qui charge `Image` + initrd + DTB et appelle `booti` (à vérifier avec
  `help booti` dans le prompt U-Boot).

La piste A est la plus propre si `u-boot.ext` démarre ; la piste B évite de
packager U-Boot. Dans les deux cas, ne pas flasher une image disque complète
à l'offset 0 : elle écraserait le bootloader vendor.
