# N5 — pré-vol de l'installateur eMMC (artefact du 2026-10-30)

> Mesures faites sur l'artefact reconstruit le 2026-10-30 après le correctif
> `init=` de `modules/image/n5-boot.nix`. **Rien n'a été flashé ni démarré** :
> tout ce qui suit est relevé sur l'image disque, sans carte. Les points C1/C2
> de `docs/installateur.md` §5 sont donc mesurés ; C3–C17 restent à jouer avec
> `scripts/bench-installateur.sh`.

## 1. Artefact

| Élément | Valeur |
|---|---|
| dérivation | `/nix/store/f4ar1ryjrw0jqswr6rwq011i0c83x2kf-nixelec-meson64-aml-s9xx-box-installer.img.drv` |
| store | `/nix/store/w5dv2bm5d5ncllyavalglaxxjdqcjbzb-nixelec-meson64-aml-s9xx-box-installer.img` |
| fichier | `sd-image/nixos-image-sd-card-26.05.20261020.cd4ea8d-aarch64-linux.img.zst` |
| sha256 `.img.zst` | `b8f1d5f507d923b79119300e631625507460e804175dfd93617dc80bb2c9ec44` |
| sha256 `.img` | `f45f8fe039d056e4eb700ef78bb5582640138877f46bbb3992e6c3012748715a` |
| taille compressée | 647 375 968 o = 617,3 Mio |
| taille décompressée | 2 845 835 264 o = 2,65 Gio (2,85 Go) |
| build | `nix build .#packages.aarch64-linux.magicsee-n5-installer-image`, ~4 min sous binfmt (cache chaud) |

L'artefact antérieur (`8j9qj790…`, `result-installer` du 27 oct. 22:01) a été
mesuré pour comparaison : 2 375 024 640 o décompressé, p2 = 1 752 Mio,
`uEnv.ini` **sans `init=` ni `video=`** — c'est bien l'artefact périmé décrit
au §3 du document. Son dérivé n'est pas `f4ar1ry…` ; il est resté dans le
store, mais le lien `result-installer` a été repointé sur la nouvelle image.

## 2. Table de partitions (C1, préalable)

```text
label: dos            label-id: 0x2178694e
p1: start=2048      size=1048576  type=b    → 1 Mio → 513 Mio, FAT32 « N5_BOOT »
p2: start=1050624   size=4507648  type=83, bootable → 513 Mio → 2714 Mio, ext4 « N5_INSTALL »
```

Conforme à `docs/installateur.md` §1.2 et §3 (p1 au secteur 2048, 1 048 576
secteurs ; p2 au secteur 1 050 624). Le superbloc ext4 porte
`LABEL=N5_INSTALL`, UUID `44444444-4444-4444-8888-888888888888` (UUID invariant
de `make-ext4-fs.nix` ; sans effet ici, la cible est reformatée par le script).

## 3. Contenu de `p1` — charge utile de l'installateur (C1, C2)

```text
Volume N5_BOOT, 9 fichiers, 165 482 043 o utilisés, 370 294 784 o libres (353 Mio)
  Image                 38 361 600
  initrd                25 176 821
  meson-gxl-s905x-p212.dtb  40 957
  s905_autoscript          775      idem boot.scr
  s905_autoscript.txt      703
  uEnv.ini                 251
  uImage                38 361 664
  uImage.multi          63 538 497
```

`uEnv.ini` (installateur) :

```text
dtb_name=/meson-gxl-s905x-p212.dtb
bootargs=console=ttyAML0,115200n8 cma=256M video=HDMI-A-1:1920x1080@60 root=LABEL=N5_INSTALL rootwait rw init=/nix/store/4bk5rs76md58mb96w00rmgqw9ayw20nx-nixos-system-n5-installer-sd-card-26.05.20261020.cd4ea8d/init
```

- **C1 = OK** : volume `N5_BOOT`, 9 fichiers, dont `boot.scr`, `uImage.multi`,
  `uEnv.ini` et le DTB nommé par `dtb_name=`.
- **C2 = OK** : `init=` non vide, pointe `/init` d'un chemin de store, et
  `root=LABEL=N5_INSTALL`. L'artefact est donc **apte au flash**, contrairement
  à celui du 27 oct. (`uEnv.ini` 112 o sans `init=`).

En-tête `uImage.multi` : magie `0x27051956`, type *multi*, arch arm64,
compression none, taille 63 538 433 o, composants `[38 361 600, 25 176 821]`
(noyau + initrd, cohérents avec `Image` et `initrd`). `boot.scr` et
`s905_autoscript` sont binairement identiques (775 o, type script).

## 4. Charge utile de la cible, embarquée dans `p2`

```text
/nix/store/l64jmpllxjn4pccbxsarpz5lj06c54r6-n5-boot-files/uEnv.ini   (240 o)
  bootargs=… root=LABEL=NIXOS_SD rootwait rw init=/nix/store/xbxmvl4nzhh4dlkwmqc957yl63kzrzf8-nixos-system-magicsee-n5-26.05.20261020.cd4ea8d/init
```

Le store de l'image (2 088 entrées) contient `nixos-system-magicsee-n5-…`
(cible) **et** `nixos-system-n5-installer-sd-card-…`, avec `/init` exécutable
pour les deux : `system.extraDependencies` a bien embarqué la clôture, donc
`nixos-install` n'aura pas besoin de réseau (préalable de C8).

## 5. Écarts entre `docs/installateur.md` et l'artefact

| # | Document | Réel | Effet |
|---|---|---|---|
| 1 | §1.2 « 2,21 Gio décompressé, 515 Mio compressé » ; §3 et §5 P0 « 2,2 Gio » | 2,65 Gio / 617 Mio. L'ancien artefact faisait bien 2 375 024 640 o (2,21 Gio), p2 = 1 752 Mio ; la nouvelle p2 fait 2 201 Mio | Le chiffre du document était juste pour l'artefact du 27 oct. La croissance (+449 Mio sur p2) vient de la clôture, pas du correctif `init=` (+50 o). Prévoir ~2,9 Go libres pour le contrôle, ~2,85 Go pour la carte ; une SD de 4 Go reste juste avec les 668 Mio de sauvegarde, 8 Go recommandé (§2.1). |
| 2 | §1.4 « `boot.scr` / `s905_autoscript` 636–744 o », §5 P2 « 744 bytes read » | 775 o (les deux) | Cosmétique : la taille dépend de la longueur du chemin `init=`. Ne pas s'en servir comme critère. |
| 3 | §1.4 « `uEnv.ini` 112–220 o » | 251 o (installateur), 240 o (cible) | Cosmétique. |
| 4 | C8 : `nix-store -qR /run/current-system \| grep -c 'nixos-system-magicsee-n5-bringup'` | Le nom de store dépend du `hostName`, pas de l'attribut de flake : `nixos-system-magicsee-n5-26.05.20261020.cd4ea8d` | **Bloquant pour le banc** : la commande du document rend 0 et ferait échouer C8 à tort. Vérifier plutôt que le chemin `init=` de la charge utile cible existe (`test -x`). |
| 5 | C12 : `init=…-nixos-system-magicsee-n5-bringup-…` | `init=…-nixos-system-magicsee-n5-26.05.20261020.cd4ea8d` | Même cause que #4 ; le motif doit être `nixos-system-magicsee-n5`, pas `…-bringup`. |
| 6 | C13 : profil `system` → `…-nixos-system-magicsee-n5-bringup-…` | `…-nixos-system-magicsee-n5-26.05.20261020.cd4ea8d` | Même cause que #4. |
| 7 | §1.5 / §2.1 : UART seule console | confirmé : `services.openssh.enable = false` dans `magicsee-n5-installer` **et** `magicsee-n5-bringup` | Le banc passe obligatoirement par la console ; `--ssh` n'existe que pour un futur banc réseau. |
| 8 | §1.4 : `uImage.multi` « 63 Mo », total « ≈165 Mo » | 63 538 497 o (60,6 Mio) et 165 482 043 o | Cohérent (unités décimales) ; RAS. |
| 9 | En-tête et §3 : « artefact du 2026-10-27 », « un `result-installer` qui traîne n'est pas une preuve » | artefact reconstruit le 2026-10-30, `result-installer` repointé sur `w5dv2bm5…` | La mise en garde reste juste ; la date et le constat « l'artefact du poste est périmé » ne le sont plus. |

Les points 4 à 6 sont les seuls à corriger dans le protocole avant le banc :
en l'état, C8/C12/C13 échoueraient sur une installation parfaitement réussie.
`scripts/bench-installateur.sh` applique déjà les motifs corrigés.

## 6. Commande de flash

Contrôle préalable — remplacer `sdX` **après** avoir identifié la carte :

```bash
IMG=/nix/store/w5dv2bm5d5ncllyavalglaxxjdqcjbzb-nixelec-meson64-aml-s9xx-box-installer.img/sd-image/nixos-image-sd-card-26.05.20261020.cd4ea8d-aarch64-linux.img.zst

lsblk -b -o NAME,SIZE,TYPE,TRAN,MODEL,SERIAL,MOUNTPOINTS
sha256sum "$IMG"        # attendu b8f1d5f5…c9ec44

CARD=/dev/sdX           # ← à remplacer
test -b "$CARD" || { echo "pas un bloc"; exit 1; }
test "$(lsblk -dno TRAN "$CARD")" = usb || { echo "pas en USB"; exit 1; }
root_disk=$(lsblk -snro NAME "$(findmnt -n -o SOURCE /)" | tail -1)
test "$CARD" != "/dev/$root_disk" || { echo "REFUS: disque système"; exit 1; }
test "$(lsblk -bdno SIZE "$CARD")" -ge 3221225472 || { echo "carte < 3 Gio"; exit 1; }
```

Écriture (l'image **décompressée** fait 2,65 Gio ; ne jamais écrire le `.zst`) :

```bash
sudo umount "${CARD}"* 2>/dev/null || true
zstd -dc "$IMG" | sudo dd of="$CARD" bs=4M iflag=fullblock conv=fsync status=progress
sync
sudo partx -s "$CARD"                       # p1 start 2048, p2 start 1050624
sudo blkid "${CARD}1" "${CARD}2"            # N5_BOOT vfat / N5_INSTALL ext4
```

Si le lecteur expose `/dev/mmcblkX`, les partitions sont `${CARD}p1` / `${CARD}p2`
(le script de banc gère les deux formes, `part_dev`).

Puis, sans rien démonter à la main :

```bash
./scripts/bench-installateur.sh --phase p1 --card "$CARD"
```

## 7. Banc

`scripts/bench-installateur.sh` (français, `set -euo pipefail`) déroule C1–C17
par phases, avec verdict `OK` / `ÉCHEC` / `À VOIR` et code de sortie 1 dès un
échec. Il ne fait que lire : `mdir`/`mtype` sur les FAT, `debugfs -R` sur ext4,
`findmnt`/`lsblk`/`hostname`/`df` sur la cible ; aucun `dd`, `mkfs`, `wipefs`,
et les montages de secours sont `ro` (ext4 : `ro,noload`). L'installation
elle-même reste manuelle — le script n'analyse que sa trace.

```bash
./scripts/bench-installateur.sh --phase p0 --image-zst "$IMG"       # C1 C2
./scripts/bench-installateur.sh --phase p1 --card /dev/sdX          # C3 C4
./scripts/bench-installateur.sh --phase p2 --uart /dev/ttyUSB1 --capture-boot 90   # C5 C6
./scripts/bench-installateur.sh --phase p3 --uart /dev/ttyUSB1      # C7 C8 C9
./scripts/bench-installateur.sh --phase p4 --uart /dev/ttyUSB1 --transcript ~/install.log  # C10 C11
./scripts/bench-installateur.sh --phase p5 --uart /dev/ttyUSB1      # C12 C13
./scripts/bench-installateur.sh --phase p6 --uart /dev/ttyUSB1 --capture-boot 90   # C14 C15 C16
./scripts/bench-installateur.sh --phase p7 --uart /dev/ttyUSB1 --capture-boot 90   # C17
./scripts/bench-installateur.sh --phase recap
```

Le transport UART a été validé sur une console simulée (pty) avec les valeurs
réelles de l'artefact ; les phases P2/P4/P6/P7 ont été jouées sur des traces
types. **Aucune de ces phases n'a été exécutée sur la carte.**

## 8. Ce qui reste non mesuré

- Le flash et le boot réel de l'installateur (C3–C6).
- La branche `mmc 1:1` de l'autoscript (C14), hypothèse centrale du §6/E11.
- `expand-root-partition` sur la SD (C9) : conditionne la sauvegarde de 668 Mio.
- `nixos-install` sans chargeur (C10) : l'avertissement + code 0 reste déduit.