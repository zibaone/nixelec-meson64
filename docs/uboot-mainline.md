# U-Boot mainline à la place du BL33 vendor (Amlogic gxl, S905L / p212)

État au 2026-11-01 : **fait sur une unité**, et automatisé dans l'installateur
(`docs/installateur.md` §1.8). Le BL2, le BL30 (SCP) et le BL31 restent ceux de
la carte ; seul le BL33 est remplacé.

## Pourquoi

Le U-Boot vendor lit correctement `Image` (38 Mo), `initrd` (25 Mo), `boot.scr`
et le DTB depuis la eMMC : il n'est pas fragile, il est **limitant**. Son BL33
décompressé (969 064 o) ne contient **ni `sysboot` ni `extlinux`** : il n'existe
aucun moyen de lui faire lire une entrée par génération. D'où la charge utile
épinglée — un `uEnv.ini` qui fige `init=/nix/store/<génération>`, et donc un
`nixos-rebuild switch` qui ne survit pas au reboot (`docs/amorcage-n5.md`).

Remplacer le BL33 par un U-Boot mainline supprime les deux problèmes d'un coup :
`extlinux` lit `extlinux/extlinux.conf`, que `nixos-install` et
`switch-to-configuration` écrivent.

## Anatomie du FIP vendor

- FIP à l'offset **0x200** (secteur 1) ; l'outillage Amlogic (`mread`,
  `partition`) travaille à cet offset, donc un dump s'écrit tel quel.
- En-tête `@AML` à 0x10 ; TOC **v2** chiffrée à 0xC000 (`0xaa640001` /
  `0x12345678`, entrées de 40 o).
- BL30 @0x4000 (`0xd600`), BL31 @0x14000 (`0x2b400`), BL33 @0x40000 (`0x7d600`,
  compressé en conteneur **LZ4C**). **Pas de BL301.**
- Adresses de chargement : BL2 = 49 152 o à `0xd9000000`, BL31 à `0x05100000`,
  BL33 à **`0x01000000`** (= `CONFIG_TEXT_BASE` du build p212).

Le firmware **installé** n'est pas celui du paquet vendor : il date du
16/08/2018, là où le paquet `.img` de 2019 en embarque un autre.

| composant | installé (2018) | paquet (2019) |
|---|---|---|
| BL2 | `04c7f439…` | `6262fc69…` |
| BL30 | `ba34a087…` | `af42f285…` |
| BL31 | `c1ef5d0d…` — **99 328 o** | `09de6202…` — 177 152 o |
| BL33 | `4bf21da1…` — 417 280 o | `df116e69…` — 513 536 o |

C'est la raison pour laquelle le FIP candidat se construit sur les composants
**lus sur la carte** et jamais sur ceux d'un paquet : flasher le FIP de 2019
aurait remplacé quatre composants au lieu d'un.

## Ce qui est écrit, et par qui

`pkgs/uboot-p212-bl33.nix` construit le BL33 (`p212_defconfig`, commit
`3973f3c4d24d` épinglé) via `buildUBoot`, évalué dans
`pkgsCross.aarch64-multiplatform` depuis x86_64 : `CROSS_COMPILE` est déjà posé
par `stdenv.cc.targetPrefix`, donc la construction reste **native** (19 s
mesurées) au lieu de tourner sous binfmt.

L'installateur relit le FIP installé, en extrait BL2/BL30/BL31, chiffre le BL33
(`gxlimg -t bl3x -c`), réassemble, **compare** les trois composants ré-extraits
à ceux d'origine, puis écrit au secteur 1 et relit le média. Détail des étapes :
`docs/installateur.md` §1.8.

## Résultats mesurés

```
U-Boot 2027.01-rc1-g3973f3c4d24d (Jan 01 1980 - 00:00:00 +0000) p212
MMC:   mmc@70000: 0, mmc@72000: 1, mmc@74000: 2
Scanning mmc 1:2...  Loading Boot0000 'mmc 1' failed
mmc2(part 0) is current device
Scanning mmc 2:1...  Found /extlinux/extlinux.conf
Retrieving file: /extlinux/extlinux.conf
Retrieving file: /Image    Retrieving file: /initrd
Starting kernel ...
```

### Numérotation des médias — trois conventions

| média | U-Boot vendor | U-Boot mainline | Linux |
|---|---|---|---|
| SD | `mmc 0` | `mmc 1` (`mmc@72000`) | `mmcblk0` |
| eMMC | `mmc 1` | `mmc 2` (`mmc@74000`) | `mmcblk1` |
| SDIO (WiFi) | — | `mmc 0` (`mmc@70000`) | `mmcblk2` |

Un autoscript épinglé à `mmc 0:1` (convention vendor) tombe sur le SDIO en
mainline : l'échec est silencieux, le chargeur retombe sur son invite. C'est ce
qui fait croire à une carte briquée. La DT p212 n'a **aucun alias `mmc*`**, donc
l'ordre par défaut est `mmc0` (SDIO) → `mmc1` (SD) → `mmc2` (eMMC) : un
`boot_targets=mmc2 mmc1 usb0` dans `CONFIG_EXTRA_ENV_SETTINGS` serait plus
juste, mais n'est pas nécessaire puisque la SD n'a pas d'`extlinux.conf` et que
l'eMMC en a un.

## Ce qui ne marche pas, ou n'est pas fait

- **Aucune récupération par USB depuis le ROM.** pyamlboot écrit (`0x11`) mais
  son `0x05` rend `Errno 5` et déconnecte ; l'outil vendor refuse le stage 0.16
  (`romStage not bl1/bl2`). Prouvé en revanche : `run update` depuis un U-Boot
  vendor **vivant** + `update partition bootloader` (`mwrite success`).
- **Carte SD à FIP** (`u-boot.sd.bin` au secteur 0) : préparée, non testée. Elle
  ne sert que si la ROM lit la SD, c'est-à-dire si le FIP **eMMC est invalide**.
- **Le bouton reset n'est pas une porte** (mesuré le 2026-11-01) : 8 cycles
  d'alimentation, dont un à froid avec le bouton tenu avant la mise sous tension,
  **câble USB A-A branché côté hôte** — dont un essai avec le **VBUS rétabli par
  227 Ω** et `amlboot` déjà en attente du périphérique — et plusieurs séries
  d'appuis. La ligne BL1 affiche `POC:3;RCY:0` et la ROM charge le FIP eMMC à
  chaque fois — jamais la carte SD pourtant valide, jamais de `1b8e:c003` en USB.
  Le mode download n'est donc pas déclenchable par le bouton, même avec un hôte
  USB présent : il ne s'active que si la ROM ne trouve **aucune** source de boot
  valide. Pressé sur un système
  en marche, le même bouton déclenche un arrêt propre : il fonctionne, mais
  c'est une **touche power**, pas une entrée de récupération échantillonnée par
  la ROM. Corollaire : les entrées en mode ROM du 2026-10-29 venaient très
  probablement d'un FIP eMMC **invalide** à ce moment-là, pas du bouton. Le ROM n'entre en USB que si le FIP eMMC est **invalide**
  (c'est ainsi qu'on l'avait atteint). Donc un BL33 valide mais qui ne démarre
  pas n'a **aucune** récupération logicielle : seule la porte `boot@SDC`
  (dongle) force la SD.
- **ATF** : `armTrustedFirmwareS905` (ATF 2.14, plateforme meson/gxbb couvrant
  GXL) est disponible et permettrait de remplacer aussi le BL31 vendor : PSCI
  maintenu, disparition du message `Error initializing runtime service
  opteed_fast`. Ce n'est pas un déblocage (le BL31 vendor fait SMP, PSCI et
  reset) et ça ne touche ni BL2 ni BL30, qui restent des blobs.
- **Dongle HDMI** (`boot@SDC` / `boot@USB`, EEPROM 24C02 en I2C `0x52`) :
  documenté, non fabriqué.

## Diagnostic sans console

Le build p212 n'a **pas** `CONFIG_VIDEO` : rien n'est affiché sur HDMI avant le
noyau. Trois états produisent donc le même symptôme — écran noir, LED rouge
(la DT p212 n'a aucun nœud `leds`, donc aucun logiciel ne la pilote), pas de
réseau :

| état | ce qui le distingue |
|---|---|
| hors tension | rien sur l'UART, pas d'énumération USB |
| invite `=>` | `Hit any key to stop autoboot` puis `=>` ; `boot` relance |
| mode download du ROM | ligne `BL1` puis silence ; `1b8e:c003` côté hôte si VBUS présent |

Ordre de vérification : `ping` l'IP (si elle répond, la boîte a booté), puis
l'UART, puis l'HDMI. L'autoboot s'arrête au **premier caractère reçu** pendant
les deux secondes du décompte — avec un adaptateur TX connecté, un appui
malencontreux suffit à laisser la boîte à l'invite.

## Pièges

- `booti` exige un noyau **aligné sur 2 Mio** : `0x1080000` ne l'est pas.
  Utiliser `0x2000000`.
- `bootm` refuse un initrd brut (« Wrong Ramdisk Image Format ») ; `booti`
  l'accepte sous la forme `adresse:taille`.
- `stat -c %s` sur un lien du store mesure le lien (96 o) : utiliser `stat -L`.
- `cp` **sans** `-L` copie des liens, que FAT ne connaît pas.
- `gxlimg -t fip -e <in> <dir>` **ne crée pas** `<dir>` : `mkdir -p` d'abord.
- Le mainline du build p212 a `fatmkdir`/`fatwrite`/`fatrm` (`CONFIG_FAT_WRITE`)
  mais **pas** `fatmv` : pour neutraliser `boot.scr`, c'est `fatrm`.
- Un `extlinux.conf` avec `root=LABEL=…` est ambigu quand la SD et la eMMC
  portent la même étiquette (`NIXOS_SD`) : épingler par `PARTUUID`
  (`part list mmc N` donne la signature MBR) ou donner une étiquette distincte
  à la cible.
