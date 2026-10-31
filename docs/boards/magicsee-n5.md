# Magicsee N5 — bring-up

> **Statut** : boot eMMC **autonome** mesuré le 2026-10-31 (HavenOS kiosque, sans
> carte SD) ; boot SD mesuré le 2026-10-26 (LibreELEC 6.14.2, UART) ; décodage
> matériel sous Kodi mesuré le 2026-10-28 (fichier local) et le 2026-10-31 (flux
> d'addon 1080p).
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
| Ethernet | `meson8b-dwmac`, PHY interne GXL, RMII |
| WiFi | **QCA9377**, `ath10k_sdio`, SDIO `0271:0701` |
| Bluetooth | QCA9377 combo, mais **mal bindé par le DTB p212** (voir plus bas) |
| IR | `meson-ir`, décodeur NEC, `event0` |
| CEC | `meson-ao-cec`, `/dev/cec0` |
| GPU | Lima Mali-450, `/dev/dri/card1`, `renderD128` |
| Display | `meson-drm`, `/dev/dri/card0` |
| Audio | `gx-sound-card`, carte 0 `S905X-P212` |
| USB | xHCI (root hub) + dwc2 OTG ; aucun périphérique testé |
| VPU | `meson-amvdec` **stateless** (noyau 7.0.14 de la couche), H.264 et HEVC mesurés |
| UART | `ttyAML0`, 115200 8N1 |

Détails utiles :

- eMMC : CID `1501004d…` (tronqué, identifiant unique non publié), fabricant `0x15`,
  produit `MAG2GC`, date `04/2014`, boot0/boot1 et RPMB de 4 MiB chacun.
- WiFi : firmware `WLAN.TF.1.1.1-00061-QCATFSWPZ-1 api 5` ; le message
  `failed to fetch board data … board-2.bin` suivi de `board_file api 1` est le
  comportement **normal** en mainline (le `board-2.bin` d'`armbian/firmware` ne
  contient que des entrées `bus=pci`). Le repli sur `board.bin` fonctionne, et
  l'association est validée (DHCP, `192.168.1.21`).
- Bluetooth : le DTB p212 décrit un contrôleur Broadcom ; le kernel tente
  `hci_uart_bcm` et échoue (`Failed to set baudrate`). Le matériel est un
  QCA9377 et doit utiliser `btqca`/un nœud DT QCA.
- IR : `meson-ir` sur `c8100580.ir`, récepteur brut + keymap NEC.
- CEC : `meson-ao-cec`, adresse physique `2.0.0.0` obtenue de la TV le 2026-10-28.
- GPU : Lima probe, mais avertissement `_opp_set_regulators: no regulator
  (mali) found` (non bloquant).
- VPU : `/dev/video0` (`meson-video-decoder`) expose `H264_SLICE` en sortie et
  `NV12M` en capture, ce qui fait de cette boîte une cible **stateless**. C'est
  le mode par défaut de la couche (`nixelec.vpu.mode = "stateless"`).

## eMMC et disposition mesurée (2026-10-31)

La eMMC fait **16 Go nominaux**, pas 32 Go : le kernel et `parted` rapportent
14,56 GiB (15,63 Go décimaux, `30535680` secteurs de 512 octets). Les 32 Go
vus par l'utilisateur sont la carte SD. La capacité est confirmée par `parted`
et par le CID de la puce.

Disposition (MBR) :

| Partition | Début | Taille | FS | Libellé | Rôle |
|---|---|---|---|---|---|
| — | 0 | 668 MiB | — | — | bootloader vendor + environnement U-Boot |
| `mmcblk1p1` | secteur 1368064 | 488 MiB | **FAT32** | `NIXOS_BOOT` | charge utile d'amorçage |
| `mmcblk1p2` | 1157 MiB | 13,43 GiB | ext4 | `NIXOS_SD` | racine NixOS |

Le premier **668 MiB** n'est pas une partition : il contient le bootloader
vendor (BL1/BL2/BL31/BL33) et l'environnement U-Boot. **Toute installation sur
eMMC doit préserver cette zone.** La table ci-dessus satisfait la contrainte :
`p1` commence exactement au secteur 1368064, et le script d'installation ne
repartitionne jamais.

Contenu au 2026-10-31 : HavenOS kiosque, **2,7 Gio utilisés sur 14** (système
`glxnsrfmq9jzxc6k04i5yd833whn0faw-nixos-system-aml-s9xx-box-edge-kodi-…`).

## Boot mesuré

### Depuis la carte SD (2026-10-26, LibreELEC)

1. Boot ROM → BL1 GXL (`9ac50e`) → BL2 (2017) → BL31 (2017) → BL33, chargés
   depuis la **eMMC**.
2. U-Boot vendor **2015.01** (16 août 2018), DRAM 2 GiB.
3. Il lit `s905_autoscript` sur la carte SD, charge `KERNEL` (uImage legacy lzo)
   + `uEnv.ini` + `amlogic/meson-gxl-s905x-p212.dtb`, et fait `bootm`.

### Depuis la eMMC (2026-10-31, HavenOS kiosque, **sans carte SD**)

```
GXL:BL1:9ac50e:bb16dc;FEAT:ADFC318C:0;POC:3;RCY:0;EMMC:0;READ:0;…
reading emmc_autoscript
Booting NixOS from mmc 1:1
   Verifying Checksum ... OK
   Verifying Checksum ... OK
[    0.000000] Linux version 7.0.14 …
[    2.259277] Freeing initrd memory: 24568K
…
aml-s9xx-box-edge-kodi login:
```

La ROM GXL essaie SPI → eMMC → NAND → SD → USB : elle lit donc
`emmc_autoscript` sur `mmc 1:1`. Le script charge `uImage` (`0x20000000`),
`uInitrd` (`0x13000000`) et le DTB (`0x1000000`), puis appelle **`bootm` à trois
arguments**.

### Le seuil de lecture FAT du vendor U-Boot

Le conteneur `uImage.multi` (63,5 Mo) faisait échouer le démarrage :
`Verifying Checksum ... Bad Data CRC` puis `can't get kernel image!`. Mesuré au
prompt U-Boot, fichier par fichier :

| fichier | taille | CRC relu |
|---|---|---|
| `initrd` | 25 Mo | identique |
| `Image` | 38 Mo | identique |
| `uImage.multi` | 63,5 Mo | **faux** |

Le fichier est intact (comparé au store en `ro`), c'est la **lecture FAT du
vendor au-delà d'environ 38 Mo** qui est fausse. D'où la recette retenue :
`uImage` (36,6 Mo) + `uInitrd` (24 Mo), tous deux sous le seuil. Voir
[`installateur.md`](../installateur.md) pour le détail de la mesure.

## DTB retenu

`amlogic/meson-gxl-s905x-p212.dtb` est le DTB de travail :

- il boote, et il fait tourner un kiosque Kodi en 1080p60 ;
- il expose Ethernet, WiFi QCA9377, IR, CEC, GPU Lima et la carte son ;
- il n'expose **pas** le bouton reset (`gpio-keys` absent) ;
- son nœud Bluetooth est Broadcom, alors que le module est QCA9377.

Un DTB qui boote ne suffit pas. Le bon DTB doit garder Ethernet, WiFi, IR,
SD, eMMC, CEC, GPU et audio. Pour le Bluetooth QCA9377, prévoir un overlay
ou un DTS dérivé de p212 plutôt qu'un DTB d'une autre boîte.

## Points à mesurer ensuite

- [x] SoC exact : GXL S905L (`0x21`, `21:d`)
- [x] RAM : 2 GiB
- [x] eMMC : 16 Go classe, 14,56 GiB, MAG2GC
- [x] Boot SD via vendor U-Boot + `s905_autoscript`
- [x] Boot **eMMC autonome** (HavenOS kiosque, sans SD) — 2026-10-31
- [x] DTB de travail : p212
- [x] Ethernet : driver + PHY interne, lien direct mesuré (IPv6 lien-local)
- [x] WiFi : QCA9377, association + DHCP (`192.168.1.21`)
- [ ] Bluetooth : QCA9377 avec nœud DT correct
- [x] IR : `meson-ir` + NEC
- [x] HDMI vidéo (kiosque 1080p60) — reste l'audio HDMI à re-mesurer sur cette boîte
- [x] CEC : lien et adresse physique `2.0.0.0` (pilotage Kodi non fait)
- [x] GPU Lima
- [ ] Bouton reset (absent du DTB p212)
- [ ] Périphérique USB
- [x] VPU stateless : `H264_SLICE` exposé, H.264 et HEVC décodés en matériel
- [x] Provisioning des secrets (WiFi + serveur web Kodi) — 2026-10-31

## Conséquences pour le VPU

- H.264 est la cible sûre sur GXL/S905L, et c'est mesuré.
- HEVC et HEVC 10 bits sont **mesurés** sur cette boîte (2026-10-30) : le VPU
  stateless les décode, y compris `EXT_SPS_ST_RPS` géré côté noyau (voir D1 de
  `plan-travaux-restants.md`).
- Le DTB p212 active le VPU (`vpu@d0100000`, compatible
  `amlogic,meson-gxl-vpu`).
- Le driver staging reste désactivé dans le noyau (`CONFIG_VIDEO_MESON_VDEC=n`)
  au profit de `meson-amvdec`.

## Installation eMMC — méthode mesurée le 2026-10-31

La méthode recommandée au 26/10 (disko + image installateur) n'a pas été
utilisée : la table de partitions existante était **déjà correcte** (`p1` au
secteur 1368064), et disko ne sait pas décrire une table qui préserve le
chargeur vendor sans risque. La méthode retenue ne touche **pas** la table :

1. Amorcer une image HavenOS (ou l'installateur) depuis la carte SD ;
2. formater les deux partitions existantes (`p1` en FAT32 `NIXOS_BOOT`,
   `p2` en ext4 `NIXOS_SD`) — jamais le secteur 0 ;
3. recopier la charge utile d'amorçage sur `p1` ;
4. `nixos-install --root /mnt --system /run/current-system --no-root-password`
   (le système est **le système courant**, donc la fermeture est déjà sur place) ;
5. éteindre, **retirer la carte SD**, rallumer : la ROM lit
   `emmc_autoscript` et démarre depuis la eMMC.

L'avertissement `do not know how to make this configuration bootable; please
enable a boot loader` est **attendu** : la charge utile est épinglée hors du
système et c'est nous qui la posons sur `p1`.

## Révision du 2026-10-31

Cette page a été corrigée en place. Ce qu'elle affirmait au 26/10 et pourquoi
c'était faux :

| affirmation d'origine | réalité mesurée |
|---|---|
| « le boot d'une image nixbian n'est pas encore prouvé » | boot SD le 26/10 puis **boot eMMC autonome** le 31/10 |
| « VPU stateless : à mesurer » | `meson-amvdec` stateless décode H.264 et HEVC, sous FFmpeg **et** sous Kodi |
| « la méthode recommandée est disko » | disko écarté : la table existante est conservée, seule la charge utile et la racine sont réécrites |
| partitions `BOOT_EMMC` / `ROOT_EMMC`, FAT16 | `NIXOS_BOOT` (FAT32) / `NIXOS_SD`, et c'est ce que lit la charge utile |
| « HDMI débranché, audio et CEC non validés » | HDMI validé (kiosque 1080p60), CEC `2.0.0.0` obtenu le 28/10 |

Les défauts connus de la chaîne d'amorçage (charge utile qui cherche `mmc 0`
avant `mmc 1`, `uImage.multi` encore produit, charge utile épinglée non suivie
par un `switch`) sont relevés dans `HavenOS/HANDOFF.md`, session du 2026-10-31.
