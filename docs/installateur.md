# Installateur eMMC — image `magicsee-n5-installer`

> **Statut** : code écrit, image construite (artefact du 2026-10-27),
> **jamais démarrée sur la carte**. Tout ce qui suit est déduit du code
> (`modules/image/meson64-installer.nix`, `modules/image/n5-boot.nix`,
> `modules/image/meson64-sd.nix`) et des mesures faites sur l'image SD
> (`docs/diagnostics/n5-uboot-boot-2026-10-27.md`). Les seules valeurs
> « relevées » viennent de l'artefact `/nix/store/…-installer.img` présent
> sur le poste, pas d'un boot.
> Le §5 est le protocole qui reste à exécuter pour transformer ces
> déductions en mesures.

## 0. Périmètre

L'installateur installe **un** système, déjà construit et figé dans l'image,
sur les **partitions existantes** `mmcblk1p1` / `mmcblk1p2`, après avoir
sauvegardé la zone du bootloader vendor.

| Fait | Ne fait pas |
|---|---|
| écrit dans `p1` et `p2` de `/dev/mmcblk1` | ne crée ni ne redimensionne de partition |
| formate `p1` en FAT32 `NIXOS_BOOT`, `p2` en ext4 `NIXOS_SD` | ne touche pas aux 668 premiers MiB (bootloader vendor) |
| copie la clôture de `magicsee-n5-bringup` par `nixos-install` | n'installe aucun chargeur d'amorçage |
| pose la charge utile `uImage.multi` + `boot.scr` + DTB dans `p1` | ne sauvegarde pas le contenu de `p1`/`p2` (l'ancien système est perdu) |
| sauvegarde 668 MiB + `boot0` + `boot1` | ne peut pas installer une autre configuration que celle de l'image |

Ce n'est donc pas un installeur générique : c'est une image de maintenance
qui applique une cible connue sur une disposition eMMC connue.


## Premier banc réel — 30/10, N5, eMMC 14,6 Gio

Déroulé complet sur la carte, console série 115200, SD = image installateur,
cible = eMMC. Données de l'eMMC déclarées jetables par l'opérateur (Ubuntu 20.04
« arm-64 » avec `/home/meh`, 2,9 Gio).

| phase | résultat |
|---|---|
| p0 | **OK** — 9 fichiers, 165 458 265 o, `root=LABEL=N5_INSTALL`, `init` non vide |
| p3 | **OK** — `start(p1)` = 1368064 (seuil atteint), cible `EXECUTABLE` dans le store, 1566 Mio libres |
| p4 | **OK** — `nixos-install` a copié `…-nixos-system-magicsee-n5-…`, « installation finished! », avertissement chargeur attendu |
| p5 | **OK** — p1 = `NIXOS_BOOT` avec 9 fichiers et `init=xbxmvl4n…` ; p2 = `NIXOS_SD`, `init` exécutable, 601 entrées de store |
| p6 | **ÉCHEC** — voir ci-dessous |

### Pourquoi la eMMC ne démarrait pas

Deux causes distinctes, mesurées depuis le prompt U-Boot vendor
(`gxl_p212_v1#`) puis sur la carte.

1. **Le nom du script d'amorçage.** L'environnement vendor fait
   `start_emmc_autoscript = fatload mmc 1 1020000 emmc_autoscript && autoscr 1020000`,
   alors que la charge utile ne fournissait que `s905_autoscript` — le nom attendu
   côté SD (`start_mmc_autoscript = fatload mmc 0 1020000 s905_autoscript`). Sans
   `emmc_autoscript`, il tombe sur `storeboot` (Android, effacé) puis rend la main
   au prompt.
2. **Une copie corrompue.** Le `uImage.multi` lu sur la eMMC différait du store :
   `cmp` a trouvé **31 octets faux, contigus** (31 249 250 → 31 249 275), à
   **taille identique** (63 527 012 o, exactement celle du store), sans aucune
   erreur MMC dans `dmesg`. D'où, au `bootm` :
   `Verifying Checksum ... Bad Data CRC` puis `ERROR: can't get kernel image!`.
   `Image` et `initrd` étaient intacts, et `mkimage -l` valide le fichier du
   store : c'est bien la copie vers la FAT qui était en cause, pas l'image.

**Le chargeur n'était pas en cause**, contrairement à la première lecture de ce
banc : l'image SD n'écrit aucun binaire d'amorçage (`firmwarePartitionOffset = 1`,
premier MiB vide). Le SoC retombe sur le U-Boot de la eMMC, qui charge ensuite
`s905_autoscript` depuis la SD (`mmc 0`). Le même chargeur amorce donc les deux
médias : seule la donnée sur la FAT était fausse.

Après recopie vérifiée (`cmp` = 0) et pose manuelle de `emmc_autoscript`, la carte
démarre depuis `EMMC:0`, sur `/dev/mmcblk1p2`, avec le toplevel installé.

### Résultat du banc

| point | mesure |
|---|---|
| C14 (boot eMMC) | **OK** — `GXL:BL1 … EMMC:0`, `Booting NixOS from mmc 1:1` |
| C15 (identité) | **OK** — `/run/current-system` = `/nix/store/xbxmvl4n…-nixos-system-magicsee-n5-…`, racine `/dev/mmcblk1p2` |
| C16 (état) | **OK** — `systemctl is-system-running` = `running`, **0 unité en échec**, `hostname` = `magicsee-n5` |
| C17 (persistance) | **OK** — second démarrage, même toplevel, 0 échec |

Le doute sur `/etc/hostname` est levé : lu depuis l'installateur il rendait
`n5-installer` parce que `/etc/static` est un lien **absolu** vers `/nix/store`,
résolu dans l'espace de noms de l'installateur. Au démarrage, la carte porte bien
`magicsee-n5`.

### Correctifs portés dans l'installateur

- `n5-boot.nix` publie `emmc_autoscript` en plus de `s905_autoscript` — même
  script, il tente déjà `mmc 0:1` puis retombe sur `mmc 1:1` ;
- `meson64-installer.nix` monte p1 en écriture explicite (`-o rw`), puis
  **vérifie chaque fichier octet par octet** après `sync` et `drop_caches` — sans
  le `drop_caches` la comparaison lit la page cache de l'écriture et valide une
  copie fausse — reprend une fois en recréant le fichier, et **s'arrête** si
  l'écart persiste au lieu de laisser une carte non amorçable.
## 1. Ce que fait l'image, étape par étape

### 1.1 D'où elle vient

```text
flake.nixosConfigurations.magicsee-n5-installer          parts/configurations.nix:24
  specialArgs  n5TargetSystem / n5TargetKernel / n5TargetDtb / n5TargetBootParams
  modules      magicsee-n5 + sd-image + installer + examples/magicsee-n5-installer.nix
flake.packages.aarch64-linux.magicsee-n5-installer-image parts/configurations.nix:57
```

`n5TargetSystem` est le toplevel de `magicsee-n5-bringup` — **pas** celui de
`magicsee-n5-sd` et pas celui de l'installateur lui-même. L'installateur
embarque donc un système cible sans `sd-image`, sans kiosque, avec Nix
désactivé (§1.7).

### 1.2 L'image disque

Produite par `modulesPath + "/installer/sd-card/sd-image.nix"` avec les
réglages de `meson64-sd.nix` :

| Élément | Valeur | Source |
|---|---|---|
| table | MBR (`dos`), `label-id: 0x2178694e` | sd-image.nix |
| trou avant `p1` | 1 MiB | `firmwarePartitionOffset = 1` |
| `p1` | 1 MiB → 513 MiB, type `b`, FAT32, label `N5_BOOT` | `firmwareSize = 512`, `firmwarePartitionName` |
| `p2` | à partir de 513 MiB, type `83`, bootable, ext4, label `N5_INSTALL` | `rootVolumeLabel`, `expandOnBoot` |
| compression | zstd | `compressImage = true` (défaut) |

Mesuré sur l'artefact du 2026-10-27 : **2,21 Gio décompressé, 515 Mio
compressé**. La partition racine s'agrandit au premier démarrage
(`expand-root-partition`, conditionné à l'existence de
`/nix-path-registration`) ; c'est ce qui donnera les 800 MiB libres exigés
par le script (§4).

**Piège de nommage** : `image.fileName` est forcé à
`nixelec-meson64-aml-s9xx-box-installer.img` (`meson64-installer.nix:102`),
ce qui nomme le **répertoire de store**, pas le fichier. Le fichier interne
reste `sd-image/nixos-image-sd-card-<label>-aarch64-linux.img.zst` parce que
`sd-image.nix` construit `$out/sd-image/${image.baseName}.img` puis le
compresse. Toujours désigner le fichier par glob, jamais par son nom supposé.

### 1.3 La charge utile de l'installateur (pour se démarrer lui-même)

`meson64-sd.nix:10-17` appelle `mkBootFiles` avec
`rootLabel = config.sdImage.rootVolumeLabel` — soit `N5_INSTALL` — et
`toplevel = config.system.build.toplevel`. Les bootargs contiennent donc
`root=LABEL=N5_INSTALL … init=/nix/store/<hash>-nixos-system-n5-installer-sd-card-<ver>/init`.

C'est volontaire : l'installateur et la cible n'ont **aucune étiquette
commune**, sinon les deux systèmes se disputeraient `/dev/disk/by-label`.

### 1.4 La charge utile de la cible (embarquée)

`meson64-installer.nix:13-20` rappelle `mkBootFiles` avec :

| argument | valeur | conséquence |
|---|---|---|
| `kernel` | noyau de `magicsee-n5-bringup` | même noyau que la cible |
| `initrd` | `${n5TargetSystem}/initrd` | initrd de la cible |
| `rootLabel` | `"NIXOS_SD"` — **en dur** | ne suit pas une éventuelle modification de l'exemple |
| `bootParams` | `boot.kernelParams` de la cible | `console=ttyAML0,115200n8 cma=256M video=HDMI-A-1:1920x1080@60` |
| `toplevel` | `n5TargetSystem` | `init=` pointe sur le système à installer |

Les deux charges utiles ont la même forme, produite par le même
`mkBootFiles` (`n5-boot.nix:53-64`) :

| fichier | rôle | ordre de grandeur |
|---|---|---|
| `uImage.multi` | noyau + initrd, **le seul chargé au boot** | 63 Mo |
| `boot.scr` / `s905_autoscript` | script U-Boot (mkimage, même contenu) | 636–744 o |
| `s905_autoscript.txt` | source lisible du script | idem |
| `uEnv.ini` | DTB + bootargs lisibles ; **non lu** par notre autoscript (hérité du vendor) | 112–220 o |
| `meson-gxl-s905x-p212.dtb` | DTB chargé à `0x1000000` | 41 Ko |
| `uImage` / `Image` / `initrd` | noyau et initrd séparés, jamais chargés par l'autoscript actuel | 38 / 38 / 25 Mo |

Total ≈ 165 Mo : cela tient dans les 488 Mio de `p1` avec ~300 Mo de marge.
Un noyau plus gros (kiosque) rapprocherait de la limite.

Le script généré (`n5-boot.nix:28-47`) essaie `mmc 0:1` puis `mmc 1:1` :

```text
setenv mmcdev 0
if fatload mmc 0:1 ${uimage_addr} uImage.multi; then
  setenv mmcdev 0
else
  setenv mmcdev 1
  fatload mmc 1:1 ${uimage_addr} uImage.multi
fi
```

`mmc 0` = carte SD, `mmc 1` = eMMC (mesuré : `mmcblk0` = SD, `mmcblk1` =
`MAG2GC`). **La branche `mmc 1` n'a jamais été exercée** : c'est
l'hypothèse centrale de tout l'installateur, et le §5 est construit autour
d'elle.

### 1.5 Le script `/etc/n5/install.sh`

`environment.etc."n5/install.sh"` (ligne 116) installe le script produit
lignes 22-99. Déroulé réel :

| # | action | lignes |
|---|---|---|
| 1 | arguments : `$1` = disque (`/dev/mmcblk1`), `$2` = sauvegarde (`/var/lib/n5-backup`) | 25-28 |
| 2 | refuse si `EUID != 0` | 30-33 |
| 3 | refuse si `$1` n'est pas un bloc | 34-37 |
| 4 | **refuse si `p1`/`p2` n'existent pas** — aucun repartitionnement | 39-44 |
| 5 | refuse si `start(p1) < 1368064` secteurs (= 668 MiB) | 46-50 |
| 6 | refuse si la cible est le disque qui porte `/` (comparaison `findmnt` + `lsblk`) | 52-57 |
| 7 | exige ≥ 800 MiB libres dans `$2` | 59-64 |
| 8 | affiche la cible et demande littéralement `YES` sur le terminal | 66-69 |
| 9 | `dd` des 668 premiers MiB → `prefix-668MiB.img` | 71 |
| 10 | `dd` de `mmcblk1boot0`/`boot1` **si les nœuds existent** (silencieusement sinon) | 72-76 |
| 11 | `umount p1 p2` (best effort) | 78-79 |
| 12 | `wipefs -a p1 p2` — supprime les signatures, donc aucun prompt de `mkfs` | 80 |
| 13 | `mkfs.vfat -F 32 -n NIXOS_BOOT p1`, `mkfs.ext4 -L NIXOS_SD p2` | 81-82 |
| 14 | monte `p2` sur `/mnt/n5`, `p1` sur `/mnt/n5/boot`, `trap cleanup EXIT` | 84-92 |
| 15 | `nixos-install --root /mnt/n5 --system "$target_system" --no-root-passwd` | 94 |
| 16 | `cp -r "$target_boot"/. /mnt/n5/boot/` puis `sync` | 95-96 |
| 17 | message « remove the SD card and boot from eMMC », puis démontage par le `trap` | 98, 88-92 |

Points à retenir :

- la taille et l'offset des partitions **ne changent pas** : seuls les
  systèmes de fichiers sont refaits ;
- la sauvegarde est sur le **disque de l'installateur** (la SD), pas sur la
  cible — elle disparaît si la SD est réécrite (§4) ;
- `set -euo pipefail` + `read` : lancé sans terminal (ssh, redirection), le
  script meurt sur EOF avant tout `dd` ;
- `$disk` est concaténé en `${disk}p1` : cela ne fonctionne que pour les
  noms `mmcblk*` / `nvme*n1`. `/dev/sda` produirait `/dev/sdap1` et
  échouerait au test 4, pas au test 3 ;
- la garde 6 compare des chaînes : passer `/dev/disk/by-id/…` la contourne ;
- **tous** les refus (étapes 2 à 7) précèdent la première écriture : une erreur
  du script ne laisse jamais la eMMC à moitié traitée.

### 1.6 Ce que fait `nixos-install` ici

Avec `--root` et `--system` (nixpkgs `nixos-install.sh`) :

1. crée un répertoire temporaire dans `/mnt/n5` (supprimé à la sortie) ;
2. saute la copie du canal : `nix-env -q nixos` sur un profil `channels`
   inexistant ou vide ne rend rien (image construite par flake, `nix.nixPath`
   forcé à `[]` par `modules/system/minimal.nix:44`) ;
3. `nix-env --store /mnt/n5 -p /mnt/n5/nix/var/nix/profiles/system --set
   "$target_system"` : **copie toute la clôture** depuis le store local vers
   `/mnt/n5/nix/store`. Aucun réseau n'est utilisé — la cible est dans le
   store de l'installateur grâce à `system.extraDependencies`
   (`meson64-installer.nix:111-114`) ;
4. `touch /mnt/n5/etc/NIXOS` ;
5. étape « installing the boot loader » : `nixos-enter` lance l'activation de
   la cible puis `switch-to-configuration boot`. Comme GRUB et extlinux sont
   désactivés (`mkForce false`, `modules/boards/magicsee-n5.nix:20-21`),
   `system.build.installBootLoader` reste le script par défaut de nixpkgs,
   qui imprime
   `Warning: do not know how to make this configuration bootable; please enable a boot loader.`
   et sort en 0. Ce n'est donc **pas** une erreur — c'est le comportement
   attendu, et c'est la même phrase que cite `HavenOS/parts/packages.nix`
   pour justifier `havenos-n5-boot-payload` ;
6. `--no-root-passwd` : pas d'invite de mot de passe, le compte root de la
   cible reste sans mot de passe (l'autologin getty s'en charge).

L'étape 5 explique aussi pourquoi `p1` doit être **déjà montée** sur
`/mnt/n5/boot` avant l'appel : `nixos-install` ne monte rien lui-même dans
ce mode.

Relancer le script sur une cible déjà installée reste possible : les offsets
ne bougent pas, `p1`/`p2` sont reformatées et la charge utile réécrite. Mais
la sauvegarde est réécrite **par-dessus elle-même** ; si la première copie
est la seule qui compte, la sortir de la SD avant (§4.2).

### 1.7 Le système installé

C'est `magicsee-n5-bringup` tel quel :

- `nix.enable = false`, `system.disableInstallerTools = true`,
  `register-nix-paths` désactivé (`examples/magicsee-n5-bringup.nix:17-19`) :
  **pas de Nix, pas de `nixos-rebuild`, pas de mise à jour sur place** ;
- `/` = `by-label/NIXOS_SD`, `/boot` = `by-label/NIXOS_BOOT` ;
- hostname `magicsee-n5`, autologin root, `serial-getty@ttyAML0` ;
- noyau 7.0.14 + série `meson-amvdec`, arbre de modules élagué.

Conséquence : mettre à jour ce système ne se fait pas depuis lui. On
reconstruit l'installateur, ou on réécrit la charge utile depuis un système
qui a Nix (`packages.havenos-n5-boot-payload` côté HavenOS). `nixos-rebuild`
est structurellement incapable de rendre cette carte bootable : `init=` et
l'initrd désignent le système que la charge utile amorce.

## 2. Prérequis

### 2.1 Matériel

| Élément | État requis | Pourquoi |
|---|---|---|
| Magicsee N5 d'origine (S905L/GXL, eMMC 14,56 GiB) | présent | la disposition `p1` à 668 MiB est celle de cette boîte |
| Adaptateur USB-série **3,3 V** sur l'UART | **branché** | seule console : l'image n'a ni `sshd` ni configuration réseau |
| Alimentation 5 V d'origine | branchée | un `dd` de 668 MiB sur eMMC ne survit pas à une coupure |
| Carte SD (8 Go recommandé) | branchée | 2,21 Gio d'image + 800 MiB de sauvegarde ; 4 Go laisse une marge trop faible |
| Clavier/HDMI | **inutiles** | aucune session graphique dans l'installateur |
| Réseau | **inutile** | `nixos-install` copie depuis le store local |
| Autre carte SD amorçable insérée | **absente** | l'autoscript teste `mmc 0:1` en premier : une autre carte serait démarrée à la place |
| Second système portant `NIXOS_SD` | **absent** | deux disques de même étiquette rendent `/dev/disk/by-label` indéterminé |

À vérifier avant de commencer, sur la boîte d'origine : `p1` doit commencer
à 668 MiB. Si la eMMC a déjà reçu une image disque complète (offset 0), le
script s'arrêtera (§6, E3) — et le bootloader vendor est peut-être déjà
perdu, ce qui rend l'installation inutile : sans lui la boîte ne démarre
plus, quelle que soit la qualité de `p1`/`p2`.

Le brochage UART n'est documenté nulle part dans le dépôt : les relevés
citent `ttyAML0` à 115200 8N1 et `/dev/ttyUSB1` côté hôte, sans les pads.

### 2.2 Logiciel

| Élément | État requis |
|---|---|
| Hôte de build | **aarch64-linux** (CI : `ubuntu-24.04-arm`), ou builder distant |
| Nix avec flakes | oui |
| Cache binaire `havenos` | fortement recommandé (sinon le noyau se reconstruit) |
| Hôte d'écriture de la SD | n'importe quel Linux avec `zstd`, `dd`, `partx`, `blkid` — et `mtools` pour le contrôle P0 (`nix shell nixpkgs#mtools`) |
| Terminal série | `screen`/`picocom`/script maison, 115200 8N1 |

Sur un poste x86_64, l'image est une dérivation `aarch64-linux` : sans
builder ARM ni `binfmt_misc`, on ne peut que l'évaluer
(`nix eval …drvPath`, `nix build --dry-run`).

## 3. Construire et écrire la SD

```bash
cd ~/src/nixelec-meson64        # ou le clone de travail

# 1. construire (attribut qualifié : depuis x86, .#magicsee-n5-installer-image
#    résoudrait packages.x86_64-linux, qui n'existe pas)
nix build .#packages.aarch64-linux.magicsee-n5-installer-image
ls -l result/sd-image/          # un seul *.img.zst

# 2. contrôler la charge utile AVANT d'écrire (2,2 Gio temporaires, mtools requis)
zstd -dc result/sd-image/*.img.zst > /var/tmp/n5-installer.img   # 2,2 Gio, pas /tmp si tmpfs
mdir  -i /var/tmp/n5-installer.img@@1M ::/
mtype -i /var/tmp/n5-installer.img@@1M ::/uEnv.ini

# 3. identifier la carte SD (jamais le disque système de l'hôte)
lsblk -o NAME,SIZE,TYPE,TRAN,MODEL,LABEL

# 4. écrire
sudo umount /dev/sdX* 2>/dev/null || true
zstd -dc result/sd-image/*.img.zst \
  | sudo dd of=/dev/sdX bs=4M iflag=fullblock conv=fsync status=progress
sync

# 5. vérifier la carte
sudo partx -s /dev/sdX                    # p1 start 2048, p2 start 1050624
sudo blkid /dev/sdXp1 /dev/sdXp2          # N5_BOOT vfat / N5_INSTALL ext4
sudo mount -o ro /dev/sdXp1 /mnt
ls -l /mnt
sudo umount /mnt
```

Attendu à l'étape 2 : **9 fichiers**, volume `N5_BOOT`, et dans `uEnv.ini`
une ligne de la forme

```text
bootargs=console=ttyAML0,115200n8 cma=256M root=LABEL=N5_INSTALL rootwait rw init=/nix/store/<hash>-nixos-system-n5-installer-sd-card-<ver>/init
```

L'`init=` est obligatoire : sans lui l'initrd s'arrête sur
`No init= parameter on the kernel command line` (cause racine documentée dans
`docs/diagnostics/n5-uboot-boot-2026-10-27.md`). L'artefact de store présent
sur le poste (2026-10-27 22:01) est **antérieur** à ce correctif : son
`uEnv.ini` fait 112 octets et n'a pas d'`init=`. Un `result-installer` qui
traîne n'est donc pas une preuve — reconstruire, puis contrôler.

Attendu à l'étape 5 : `p1` commence au secteur 2048 (1 MiB) et fait 1048576
secteurs (512 MiB) ; `p2` commence au secteur 1050624 (513 MiB).

## 4. La sauvegarde `/var/lib/n5-backup`

### 4.1 Ce qu'elle contient

| fichier | taille | contenu |
|---|---|---|
| `prefix-668MiB.img` | 668 MiB | BL1/BL2/BL31/BL33 vendor **et** l'environnement U-Boot, situé vers 628 MiB |
| `boot0.img` | 4 MiB | partition boot0 de la eMMC (si exposée) |
| `boot1.img` | 4 MiB | idem boot1 |

Total ≈ 676 Mo ; d'où le seuil de 800 MiB. Elle est écrite **sur la
partition racine de la SD de l'installateur**, donc :

- elle survit à l'installation,
- elle **disparaît** si la SD est réécrite — la récupérer avant.

### 4.2 La récupérer

Pas de réseau sur l'installateur : on passe par l'hôte.

```bash
# carte retirée de la N5, lecteur de l'hôte : p2 est la racine N5_INSTALL
sudo mount -o ro /dev/sdXp2 /mnt
sudo cp -a /mnt/var/lib/n5-backup ~/n5-backup-$(date +%F)
sync && sudo umount /mnt
ls -l ~/n5-backup-*/     # prefix-668MiB.img (+ boot0.img, boot1.img)
```

Faire cette copie **avant** de réutiliser la SD pour autre chose.

### 4.3 Revenir en arrière

```bash
# démarrer l'installateur (SD en place), ne rien monter de la eMMC, puis :
ls -l /var/lib/n5-backup/

# 1. bootloader vendor (668 premiers MiB)
dd if=/var/lib/n5-backup/prefix-668MiB.img of=/dev/mmcblk1 \
   bs=1M count=668 conv=fsync status=progress

# 2. partitions boot, si sauvegardées
for p in boot0 boot1; do
  [ -f /var/lib/n5-backup/$p.img ] || continue
  echo 0 > /sys/block/mmcblk1$p/force_ro     # boot0/boot1 sont en lecture seule par défaut
  dd if=/var/lib/n5-backup/$p.img of=/dev/mmcblk1$p \
     bs=1M conv=fsync status=progress
done
sync
```

Ce que cela restaure : la chaîne d'amorçage vendor, donc la capacité de la
boîte à démarrer autre chose (nouvelle SD, image vendor, LibreELEC).

Ce que cela **ne** restaure pas :

- le contenu de `p1`/`p2` (Android ou LibreELEC d'origine) — perdu au
  formatage, non sauvegardé ;
- la table de partitions (non modifiée, mais non sauvegardée) ;
- la RPMB.

Après restauration du préfixe, `p1` contient toujours la charge utile NixOS :
la boîte redémarrera NixOS. Pour un retour complet à l'état d'origine il
faut réécrire une image vendor ; le dépôt n'en fournit pas, mais HavenOS
expose `pyamlboot` (mode Mask ROM) pour le cas où le préfixe est perdu.

## 5. Protocole de banc

Convention : `N5>` = invite U-Boot, `n5-installer#` = shell de l'installateur,
`magicsee-n5#` = shell de la cible. Les sorties « attendues » sont déduites du
code et du boot SD mesuré ; aucune n'a encore été observée pour cet
installateur.

### P0 — pré-vol, sans la carte

```bash
cd ~/src/nixelec-meson64
nix build .#packages.aarch64-linux.magicsee-n5-installer-image
zstd -dc result/sd-image/*.img.zst > /var/tmp/n5-installer.img   # 2,2 Gio, pas /tmp si tmpfs
mdir  -i /var/tmp/n5-installer.img@@1M ::/
mtype -i /var/tmp/n5-installer.img@@1M ::/uEnv.ini
```

- **C1** : 9 fichiers, volume `N5_BOOT`.
- **C2** : `uEnv.ini` contient `root=LABEL=N5_INSTALL` **et** `init=/nix/store/…-nixos-system-n5-installer-sd-card-…/init`.
  Absence d'`init=` = artefact périmé, ne pas flasher.

### P1 — écriture et contrôle de la SD

Commandes du §3, étapes 3 à 5.

- **C3** : `blkid` rend `N5_BOOT` (vfat) sur `p1`, `N5_INSTALL` (ext4) sur `p2`.
- **C4** : `ls` de `p1` montre les 9 fichiers de P0.

### P2 — premier boot de l'installateur

Brancher l'UART, laisser la SD, alimenter, ouvrir la console
(`screen /dev/ttyUSB1 115200`).

Attendu, dans l'ordre :

```text
reading s905_autoscript
  744 bytes read in …
## Executing script at 01020000
reading uImage.multi
  63xxxxxx bytes read in … ms (1x.x MiB/s)
reading meson-gxl-s905x-p212.dtb
  40957 bytes read in 9 ms (4.3 MiB/s)
Booting NixOS from mmc 0:1
## Booting kernel from Legacy Image at 20000000 ...
   Image Name:   NixOS multi
   Image Type:   AArch64 Linux Multi-File Image (uncompressed)
## Loading init Ramdisk from multi component Legacy Image at 20000000 ...
Starting kernel ...
```

puis côté noyau :

```text
Linux version 7.0.14 …
Machine model: Amlogic Meson GXL (S905X) P212 Development Board
Kernel command line: console=ttyAML0,115200n8 cma=256M video=HDMI-A-1:1920x1080@60 root=LABEL=N5_INSTALL rootwait rw init=/nix/store/…
mmcblk0: mmc0:… <votre carte> … GiB    ← la SD
mmcblk1: mmc1:0001 MAG2GC 14.6 GiB     ← la eMMC
[root@n5-installer:~]#
```

- **C5** : `Booting NixOS from mmc 0:1` — on a bien démarré sur la SD, la
  eMMC n'est pas encore en cause.
- **C6** : l'invite est `n5-installer` (et non `magicsee-n5`) : on est dans
  l'installateur, pas dans la cible.

### P3 — contrôle de l'état avant écriture

```bash
blkid
findmnt -n -o SOURCE /                 # /dev/mmcblk0p2 attendu
df -Pm /var/lib | tail -1              # colonne 4 >= 800
cat /sys/class/block/mmcblk1p1/start   # >= 1368064
ls -l /etc/n5/                         # install.sh, target-boot -> /nix/store/…
nix-store -qR /run/current-system | grep -c 'nixos-system-magicsee-n5'
```

- **C7** : `start` ≥ `1368064` (668 MiB) — la zone vendor est protégée.
- **C8** : la clôture de la cible est présente dans le store de
  l'installateur (compte ≥ 1). C'est la preuve que
  `system.extraDependencies` a bien fait son travail et que
  `nixos-install` n'aura pas besoin de réseau.
- **C9** : espace libre ≥ 800 MiB. S'il manque, c'est que
  `expand-root-partition` n'a pas tourné (`ls /nix-path-registration`,
  `systemctl status expand-root-partition`) — ne pas forcer, la sauvegarde
  ne tiendrait pas.

### P4 — installation

```bash
/etc/n5/install.sh
```

Attendu :

```text
target: /dev/mmcblk1 (p1=/dev/mmcblk1p1, p2=/dev/mmcblk1p2)
backup: /var/lib/n5-backup
Type YES to overwrite p1/p2: YES
668+0 records in
668+0 records out
…
installing the boot loader...
Warning: do not know how to make this configuration bootable; please enable a boot loader.
installation finished!
installed; remove the SD card and boot from eMMC
```

- **C10** : l'avertissement `do not know how to make this configuration
  bootable` est **normal** (aucun chargeur configuré) ; toute autre erreur
  arrête le script avant le `cp` et laisse `p1` vide.
- **C11** : `mount | grep /mnt/n5` ne rend rien après la sortie (le `trap` a
  démonté). Un montage résiduel signalerait une sortie par signal.

### P5 — vérification sans redémarrer

```bash
blkid /dev/mmcblk1p1 /dev/mmcblk1p2        # NIXOS_BOOT vfat / NIXOS_SD ext4
mkdir -p /mnt/p1 /mnt/p2
mount -o ro /dev/mmcblk1p1 /mnt/p1
mount -o ro /dev/mmcblk1p2 /mnt/p2
ls -l /mnt/p1                               # 9 fichiers, mêmes tailles que P0
diff -r /etc/n5/target-boot /mnt/p1         # aucune sortie
cat /mnt/p1/uEnv.ini
ls -l /mnt/p2/nix/var/nix/profiles/system   # -> /nix/store/…-nixos-system-magicsee-n5-…
ls /mnt/p2/nix/store | wc -l                # plusieurs centaines
umount /mnt/p1 /mnt/p2
```

- **C12** : `uEnv.ini` de la **cible** porte `root=LABEL=NIXOS_SD` et
  `init=/nix/store/…-nixos-system-magicsee-n5-…/init` — pas
  `N5_INSTALL`, pas `n5-installer`.
- **C13** : le profil `system` de la cible pointe sur un chemin de store
  **présent** dans `/mnt/p2/nix/store` (sinon la clôture n'a pas été copiée et
  le boot finira en panique `Attempted to kill init`).

### P6 — la preuve : boot depuis la eMMC sans SD

```bash
poweroff
# retirer la carte SD (obligatoire : mmc 0:1 gagne toujours)
# couper l'alimentation 10 s, remettre
```

Attendu :

```text
reading s905_autoscript          ← lu depuis la eMMC cette fois
## Executing script at 01020000
reading uImage.multi
Booting NixOS from mmc 1:1       ← LA ligne qui compte
…
Kernel command line: … root=LABEL=NIXOS_SD rootwait rw init=/nix/store/…-nixos-system-magicsee-n5-…/init
mmcblk1: mmc1:0001 MAG2GC 14.6 GiB
[root@magicsee-n5:~]#
```

Puis, dans la cible :

```bash
findmnt -n -o SOURCE /          # /dev/mmcblk1p2
lsblk                           # aucun mmcblk0 : la SD est absente
cat /proc/cmdline               # root=LABEL=NIXOS_SD + init=…-bringup-…
hostname                        # magicsee-n5
```

- **C14** : `Booting NixOS from mmc 1:1` — la branche de repli de
  l'autoscript fonctionne, donc le vendor U-Boot lit `s905_autoscript` puis
  `uImage.multi` sur la eMMC.
- **C15** : `findmnt` = `/dev/mmcblk1p2` **et** `lsblk` sans `mmcblk0`.
  C'est la conjonction des deux qui prouve le boot eMMC : la ligne U-Boot
  seule pourrait venir d'une SD mal lue, et `findmnt` seul ne dit pas d'où
  vient le chargeur.
- **C16** : hostname `magicsee-n5`, pas `n5-installer`.

### P7 — persistance

Couper l'alimentation, remettre, sans SD. Attendu : même séquence que P6,
même `findmnt`, `uptime` reparti de zéro. Un second boot identique écarte
l'hypothèse d'un état laissé en RAM par l'installateur.

### Contrôle négatif (facultatif, mais instructif)

Remettre la SD et démarrer : la boîte doit repartir sur `mmc 0:1` et rendre
l'invite `n5-installer`. Cela prouve que la priorité SD > eMMC est bien
celle du script, et que P6 ne doit rien au hasard.

Variante pour isoler la branche `mmc 1` **sans** retirer la carte : renommer
`uImage.multi` sur la FAT de la SD, démarrer, observer `Booting NixOS from
mmc 1:1` alors que la SD est présente, puis remettre le nom.

```bash
mren -i /dev/sdXp1 ::/uImage.multi ::/uImage.multi.bak   # et l'inverse au retour
```

### Récapitulatif des points de contrôle

| # | Phase | Critère de passage |
|---|---|---|
| C1 | P0 | 9 fichiers dans la FAT, volume `N5_BOOT` |
| C2 | P0 | `init=` présent dans `uEnv.ini` (installateur) |
| C3 | P1 | `N5_BOOT` vfat + `N5_INSTALL` ext4 |
| C4 | P1 | contenu de `p1` identique à P0 |
| C5 | P2 | `Booting NixOS from mmc 0:1` |
| C6 | P2 | invite `n5-installer` |
| C7 | P3 | `start(p1)` ≥ 1368064 |
| C8 | P3 | clôture cible présente dans le store |
| C9 | P3 | ≥ 800 MiB libres dans `/var/lib` |
| C10 | P4 | `installation finished!` + avertissement chargeur |
| C11 | P4 | plus aucun montage sous `/mnt/n5` |
| C12 | P5 | `uEnv.ini` cible = `NIXOS_SD` + `init=…-bringup-…` |
| C13 | P5 | profil `system` résolu dans le store de `p2` |
| C14 | P6 | `Booting NixOS from mmc 1:1` |
| C15 | P6 | `findmnt` = `mmcblk1p2` **et** pas de `mmcblk0` |
| C16 | P6 | invite `magicsee-n5` |
| C17 | P7 | second boot identique, `uptime` à zéro |

> **Nom de store** : il suit `networking.hostName` de la configuration, pas le
> nom de la configuration lui-même. `magicsee-n5-bringup` a pour nom d'hôte
> `magicsee-n5`, donc ses chemins sont `/nix/store/…-nixos-system-magicsee-n5-sd-card-…`.
> Chercher `…-bringup-…` dans le store échoue sur une installation pourtant
> réussie — erreur corrigée le 30/10 dans C8, C12, C13 et E13.

## 6. Modes de panne

Chaque ligne se distingue par sa **signature**, pas par une intuition.

| # | Étape | Signature | Cause probable | Discriminant |
|---|---|---|---|---|
| E1 | build | `a 'aarch64-linux' with features {} is required to build …` | pas de builder ARM | l'éval passe, le build non : `.drvPath` s'obtient sans builder |
| E2 | écriture | la carte ne montre aucune partition, ou `p1` n'est pas `N5_BOOT` | `.img.zst` écrit tel quel sans `zstd -dc` | `blkid` vide ; `partx -s` vide |
| E3 | script | `starts before 668 MiB; vendor bootloader is not protected` | table de partitions commençant à 0 (image disque complète déjà écrite) | `cat /sys/class/block/mmcblk1p1/start` < 1368064 |
| E4 | script | `expected /dev/mmcblk1p1 and /dev/mmcblk1p2; refusing to repartition` | eMMC sans MBR, ou table effacée | `fdisk -l /dev/mmcblk1`, `ls /sys/class/block` |
| E5 | script | `not a block device: /dev/mmcblk1` | eMMC non énumérée (DTB/mmc) ou mauvais nom | `lsblk` : la SD est `mmcblk0`, la eMMC `mmcblk1` |
| E6 | script | `refusing to install to the running disk /dev/mmcblk1` | on a démarré **sur la eMMC**, pas sur la SD | `findmnt -n -o SOURCE /` ; `cat /proc/cmdline` = `NIXOS_SD` |
| E7 | script | `need at least 800 MiB free in /var/lib/n5-backup` | racine de la SD non agrandie, ou carte trop petite | `df -h /`, `ls /nix-path-registration`, `systemctl status expand-root-partition` |
| E8 | fin de script | `No space left on device` pendant le `dd` de 668 MiB | seuil 800 MiB franchi mais `boot0`/`boot1` plus gros que prévu | `df -m`, `ls -l /var/lib/n5-backup` |
| E9 | `nixos-install` | `path '/nix/store/…' is not valid` | clôture cible absente du store de l'image | C8 : `nix-store -qR /run/current-system \| grep bringup` |
| E10 | `nixos-install` | `path /mnt/n5 should have permissions 755` | `umask` exotique au moment du `mkdir` | `stat -c %a /mnt/n5` |
| E11 | boot eMMC | après l'échec `mmc 0:1`, **rien** : U-Boot repart sur son `bootcmd` interne / l'ancien système / une invite | le vendor U-Boot ne cherche pas `s905_autoscript` sur `mmc 1:1` — **l'hypothèse non mesurée** | absence de `Booting NixOS from mmc 1:1` alors que `p1` contient bien le fichier (relu depuis la SD ou par `mdir` sur une image de `p1`) |
| E12 | boot cible | `[FAILED] Failed to start Find NixOS closure` puis `No init= parameter on the kernel command line`, shell d'urgence, `root account is locked` | `init=` absent de la charge utile (artefact périmé) ou `p1` non écrite | `cat` de `uEnv.ini` sur `p1` ; `diff` avec `/etc/n5/target-boot` |
| E13 | boot cible | `Kernel panic - not syncing: Attempted to kill init!` / `VFS: Cannot open root device "LABEL=NIXOS_SD"` | `init=` pointe un chemin absent du store de `p2`, ou label `NIXOS_SD` manquant | `blkid mmcblk1p2` ; `ls /mnt/p2/nix/store/<hash>-nixos-system-magicsee-n5-*` (C13) |
| E14 | boot après install | la boîte rend l'invite `n5-installer` | la SD est encore en place : `mmc 0:1` gagne | retirer la SD, refaire P6 |
| E15 | boot cible | `findmnt` = `mmcblk0p2` alors que l'U-Boot a dit `mmc 1:1` | deux disques portent `NIXOS_SD` (une image SD normale a été laissée insérée) | `blkid \| grep NIXOS_SD` |
| E16 | console | aucune sortie UART, ou caractères illisibles | mauvais débit (115200 8N1) ou adaptateur 5 V | tester avec la SD de référence connue bonne |
| E17 | script | `read -r -p` rend la main immédiatement, code 1 | script lancé sans terminal (pas de `YES` possible) | `tty` dans le shell courant |

Deux modes de panne sont **structurels** et méritent d'être reconnus comme
tels plutôt que debuggués : E11 (le vendor U-Boot ne sait peut-être pas
amorcer depuis la eMMC) et E13 (la cible est un système figé : si `init=`
et le store divergent, rien ne se répare sur place).

## 7. Questions ouvertes

1. **Le vendor U-Boot lit-il `s905_autoscript` sur `mmc 1:1` ?** Toute la
   chaîne repose sur cette hypothèse ; elle n'a jamais été exercée (le boot
   SD mesuré utilise toujours `mmc 0:1`). C'est l'objet de P6.
2. **Lit-il une FAT32 de 488 Mio sur la eMMC ?** `p1` était FAT16 ; le
   script la reformate en FAT32 sans changer le type MBR. Le FAT32 est
   prouvé sur la SD (512 Mio), pas sur la eMMC.
3. **Brochage UART** : non documenté dans le dépôt (seuls `ttyAML0`,
   115200 8N1 et `/dev/ttyUSB1` sont cités).
4. **`nixos-install` sans chargeur** : le comportement (avertissement +
   code 0) est déduit de `nixos-install.sh` et du défaut
   `system.build.installBootLoader` de nixpkgs, jamais observé sur cette
   image.
5. **`boot0`/`boot1`** : le script les sauvegarde *si* les nœuds existent,
   sans le signaler. La eMMC `MAG2GC` expose 4 Mio de boot0/boot1 selon le
   relevé, mais rien ne garantit que le noyau de l'installateur les
   exposera — à vérifier par `ls /dev/mmcblk1boot*` avant de se dire couvert.
6. **`expand-root-partition` sur la SD de l'installateur** : jamais
   observé. S'il ne tourne pas, C9 échoue et l'installation est impossible
   faute de place pour la sauvegarde.
7. **Tenue de la eMMC pendant la copie** : ~1,7 Gio écrits (668 Mio de
   sauvegarde en lecture, formatage, clôture complète). Durée et température
   non mesurées.
8. **Après restauration du préfixe**, `p1` contient toujours la charge utile
   NixOS : la boîte redémarre NixOS. Aucune procédure de retour à l'image
   vendor n'est décrite dans ce dépôt (HavenOS fournit `pyamlboot` pour le
   mode Mask ROM).
