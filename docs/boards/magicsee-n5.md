# Magicsee N5 — bring-up

> **Statut** : confirmé S905X / GXL, cible n°1.
> **Famille** : GXL / `meson64`.

## Identification

Le nom commercial « N5 » est ambigu :

| Modèle | SoC | Génération |
|---|---|---|
| Magicsee N5 | S905X | GXL |
| Magicsee N5 Plus | S905X3 | SM1 |
| Magicsee N5 Max | S905X2 ou S905X3 | G12A / SM1 |
| Magicsee N5 Max X4 | S905X4 | SC2 |

À vérifier sur la boîte :

- sérigraphie du SoC sous le dissipateur ;
- `cat /proc/device-tree/compatible` ;
- `getprop ro.board.platform` / `ro.product.device` sous Android ;
- `cat /proc/cpuinfo` (A53 x4, fréquence) ;
- module WiFi (AP6255, RTL8189FS, RTL8822CS, etc.) ;
- contrôleur Ethernet et PHY ;
- eMMC/NAND, RAM, IR, bouton reset ;
- pads UART éventuels.

## N5 S905X/GXL (confirmé)

C'est le premier target :

- `meson-amvdec` supporte GXL (H.264, HEVC, VP9, MPEG-2) ;
- le GPU est Mali-450, supporté par Lima ;
- les DTBs mainline GXL existent ;
- c'est la même famille que Le Potato, donc les tests noyau sont comparables.

### DTBs candidats

À tester dans cet ordre, avec le même noyau et une image de diagnostic :

1. `amlogic/meson-gxl-s905x-p212.dtb`
2. `amlogic/meson-gxl-s905x-nexbox-a95x.dtb`
3. `amlogic/meson-gxl-s905x-libretech-cc.dtb`
4. `amlogic/meson-gxl-s905x-khadas-vim.dtb`
5. `amlogic/meson-gxl-s905x-hwacom-amazetv.dtb`

Un DTB « qui boote » ne suffit pas : vérifier Ethernet, USB, SD/eMMC, IR,
WiFi et audio. Le bon DTB est celui qui expose le matériel réel de la boîte.

### Boot

Beaucoup de boîtes S905X n'ont pas de U-Boot mainline et démarrent avec le
vendor U-Boot. Deux méthodes :

- carte SD avec `aml_autoscript` / `s905_autoscript` + `u-boot.ext` (schéma
  Armbian `aml-s9xx-box`) ;
- UART + vendor U-Boot, chargement manuel de `Image` et du DTB.

Le schéma `u-boot.bin.sd.bin` + FIP reste la cible propre, mais ce n'est pas
le premier obstacle : d'abord prouver le boot avec le vendor U-Boot.

### Matériel à qualifier

- [ ] SoC exact et révision
- [ ] RAM / eMMC
- [ ] DTB retenu
- [ ] Ethernet
- [ ] WiFi/BT (chip + firmware)
- [ ] IR / télécommande
- [ ] HDMI + audio HDMI
- [ ] CEC
- [ ] GPU Lima / `/dev/dri`
- [ ] VPU : `/dev/video*` expose `H264_SLICE`

## Si c'est un N5 Plus / N5 Max

Le SoC est SM1 (S905X3) ou G12A (S905X2). `meson-amvdec` les supporte aussi,
mais :

- le DTB mainline de la boîte peut ne pas exister ;
- le U-Boot vendor et le layout eMMC sont spécifiques ;
- le WiFi et l'Ethernet sont souvent les points faibles (voir les problèmes
  connus du N5 Max sous Armbian).

Le N5 d'origine (GXL) reste le meilleur premier target.

## Si c'est un N5 Max X4

S905X4/SC2 : **ne pas utiliser pour le chemin stateless**. Voir
[`vontar-x4.md`](vontar-x4.md), même SoC.
