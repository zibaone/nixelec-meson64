# Vontar X4 — bring-up

> **Statut** : hors périmètre du chemin stateless.
> **SoC** : Amlogic S905X4, génération **SC2**.
> **Famille nixbian** : aucune (pas de `meson64`, pas de carte SC2).

## Pourquoi ce n'est pas un target `nixelec-meson64`

- aucune DTS SC2 dans Linux mainline 7.0/7.3 ;
- aucun defconfig U-Boot mainline SC2 ;
- `meson-amvdec` ne couvre pas SC2 ;
- le firmware SC2 existe (`sc2_av1_mmu_swap.bin`, HEVC, VP9 dans
  `jefflessard/meson-vdec-extra`), mais pas le driver.

Le Vontar X4 ne peut donc pas valider le backport `amvdec` ni le VPU
stateless. Il peut seulement servir à :

- inventaire matériel ;
- test du vendor U-Boot et du boot SD ;
- préparation d'un futur projet SC2 (vendor 5.15/6.12 ou mainline quand il
  existera).

## Ce qui existe déjà

- DTS vendor : `sib0ndt/linux-6.1.66`, PR « Add support for Vontar X4
  (4GB, GBit) », fichier
  `arch/arm64/boot/dts/amlogic/meson-sc2-s905x4-ah212-gbit-4g.dts`.
  Ce n'est pas mainline : c'est un arbre vendor 6.1.66 avec `meson-sc2.dtsi`.
- Bring-up SC2 mainline-based sur Magicsee N5 Max X4 : dépôt
  `ngocthang2710/Mainline-Linux-for-Magicsee-N5-Max-X4`, noyau
  `hkallweit/linux-amlogic-sc2` (5.18-rc2 + patchset SC2), vendor U-Boot,
  boot SD sans toucher l'eMMC. Utile comme référence SC2, pas comme base
  nixelec.
- CoreELEC : branches vendor `5.15.196_20260306` et `6.12.69_202606` avec
  DTS S4/T7 ; SC2 est à vérifier.

## Effort pour l'inclure

Estimations pour une personne expérimentée, hors aléas matériels.

| Périmètre | Base | Effort | Commentaire |
|---|---|---|---|
| Inventaire + boot test SD | vendor U-Boot + noyau SC2 | 2–5 j | UART 921600, DTS vendor, pas d'eMMC |
| Linux headless | `devmfc/linux` 6.6/6.12 ou `hkallweit` 5.18 | 1–2 sem. | clocks/pinctrl/thermal, pas de display/VPU |
| Appliance boot + display/audio/GPU | noyau vendor 5.15/6.12 | 3–6 sem. | vendor media/display, Kodi vendor |
| VPU **vendor** | CoreELEC `media_modules-aml` | 6–10 sem. | packaging + maintenance, **pas stateless** |
| VPU **stateless** | aucun driver SC2 existant | **3–6 mois** | portage/reverse engineering du VDEC SC2, firmware signé, incertitude forte |

Le point dur est le VPU stateless : il n'existe **aucun** driver SC2 dans
`hkallweit/linux-amlogic-sc2`, `devmfc/linux` ou mainline. Ces arbres n'ont
que des clocks/pinctrl/thermal et `meson-ge2d`. Le décodage SC2 n'existe que
dans la pile vendor `CoreELEC/media_modules-aml` (`amvdec`/`amvdec_ports`),
qui n'est pas l'API Request.

Conclusion : passer le X4 dans le périmètre **stateless** n'est pas un
backport, c'est un projet driver. Le X4 peut entrer dans un projet
`nixelec-meson-sc2` séparé (boot/display d'abord, VPU vendor ensuite), mais
pas dans `nixelec-meson64` en première phase.

## Si on veut tenter le X4 plus tard

1. Identifier le SoC exact et la révision de la carte (`ah212` ou variante).
2. Sauvegarder le vendor U-Boot et les partitions ; ne pas toucher l'eMMC.
3. Booter un noyau SC2 (vendor ou `hkallweit/linux-amlogic-sc2`) depuis SD
   via UART/vendor U-Boot. Baud SC2 : **921600** sur `ttyAML0`.
4. Récupérer `dmesg`, `/proc/device-tree/compatible`, les IDs SDIO/USB,
   le module WiFi et le PHY Ethernet.
5. Décider : projet `nixelec-meson-sc2` séparé, ou attente du mainline.

## Non-objectif

Ne pas essayer de faire passer le Vontar X4 pour un `meson64` : le résultat
serait un faux support, sans VPU et sans DTB mainline.
