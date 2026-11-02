{
  config,
  lib,
  pkgs,
  modulesPath,
  n5TargetSystem,
  n5TargetRootLabel,
  n5UbootBl33,
  ...
}:

let
  # gxlimg pour aarch64 : l'installateur assemble le FIP SUR LA CARTE, parce
  # que ses composants ne sont pas interchangeables d'une unité à l'autre.
  gxlimg = pkgs.callPackage ../../pkgs/gxlimg.nix { };

  # Écriture du BL33, **sans toucher aux partitions** : ce script peut être
  # lancé seul sur une carte déjà installée (remplacement du chargeur sans
  # réinstallation), ou appelé par `n5-install` en dernière étape.
  #
  # Arguments : $1 = disque (défaut /dev/mmcblk1), $2 = sauvegarde,
  # $3 = horodatage (pour réutiliser la sauvegarde d'un appelant).
  ubootScript = pkgs.writeShellScript "n5-uboot" ''
    set -euo pipefail

    bl33="${n5UbootBl33}/u-boot.bin"
    disk="''${1:-/dev/mmcblk1}"
    backup_dir="''${2:-/var/lib/n5-backup}"
    stamp="''${3:-$(date -u +%Y%m%dT%H%M%SZ)}"
    work="$(mktemp -d /tmp/n5-uboot.XXXXXX)"

    cleanup() { rm -rf "$work"; }
    trap cleanup EXIT

    if [ "''${EUID}" -ne 0 ]; then
      echo "run as root" >&2
      exit 1
    fi
    if [ ! -b "$disk" ]; then
      echo "not a block device: $disk" >&2
      exit 1
    fi
    if [ ! -f "$bl33" ]; then
      echo "BL33 mainline absent du store : $bl33" >&2
      exit 1
    fi

    mkdir -p "$backup_dir"
    avail="$(df -Pm "$backup_dir" | tail -n 1 | tr -s ' ' | cut -d' ' -f4)"
    if [ "''${avail:-0}" -lt 64 ]; then
      echo "need at least 64 MiB free in $backup_dir" >&2
      exit 1
    fi

    # 1. Sauvegarde du préfixe de 668 Mio — sauf si l'appelant vient de la
    # faire (même horodatage). Compressé : la zone est vide à 99,88 %, le
    # fichier fait ~1 Mo au lieu de 668.
    prefix="$backup_dir/prefix-668MiB-$stamp.img.zst"
    if [ -f "$prefix" ] && zstd -t -q "$prefix" 2>/dev/null; then
      echo "sauvegarde déjà présente : $prefix"
    else
      dd if="$disk" bs=1M count=668 status=none | zstd -T0 -3 -q -o "$prefix"
      zstd -t -q "$prefix"
      echo "sauvegarde : $prefix ($(stat -c %s "$prefix") octets)"
    fi

    # 2. Lecture du FIP installé. La ROM vérifie BL1→BL2 et le BL2 porte le DDR
    # init de la carte : les composants viennent donc de CETTE unité, et seul
    # le BL33 change.
    echo "lecture du FIP installé (1 Mio à partir du secteur 1)"
    dd if="$disk" of="$work/installed.bin" bs=512 skip=1 count=2047 status=none
    # gxlimg ne crée pas son dossier de sortie : sans ce mkdir il rend
    # « Cannot open dir … » et le script s'arrête là.
    mkdir -p "$work/installed"
    gxlimg -t fip -e "$work/installed.bin" "$work/installed"
    for f in bl2.sign bl30.enc bl31.enc; do
      if [ ! -f "$work/installed/$f" ]; then
        echo "composant $f introuvable : le FIP installé n'est pas reconnu" >&2
        exit 1
      fi
    done

    # Les composants extraits sont sauvés à part : quelques centaines de Ko qui
    # permettent de reconstruire un FIP sans dépendre du préfixe compressé.
    comps="$backup_dir/components-$stamp"
    mkdir -p "$comps"
    cp -a "$work/installed/bl2.sign" "$work/installed/bl30.enc" \
          "$work/installed/bl31.enc" "$work/installed/bl33.enc" "$comps/" || true
    (
      cd "$comps"
      sha256sum ./* > SHA256SUMS 2>/dev/null || true
      sha256sum "$work/installed.bin" | sed 's| .*|  installed-1MiB-from-sector1.bin|' >> SHA256SUMS
      stat -c '%s %n' ./* > MANIFEST.txt
    )
    echo "composants sauvés : $comps"

    # 3. Candidat : BL2/BL30/BL31 installés + notre BL33.
    gxlimg -t bl3x -c "$bl33" "$work/bl33.enc"
    gxlimg -t fip \
      --bl2 "$work/installed/bl2.sign" \
      --bl30 "$work/installed/bl30.enc" \
      --bl31 "$work/installed/bl31.enc" \
      --bl33 "$work/bl33.enc" \
      "$work/candidate.fip"

    # Contrôle AVANT écriture : ré-extrait du candidat, BL2/BL30/BL31 doivent
    # être identiques aux composants installés. Un écart = aucune écriture.
    mkdir -p "$work/check"
    gxlimg -t fip -e "$work/candidate.fip" "$work/check"
    for f in bl2.sign bl30.enc bl31.enc; do
      if ! cmp -s "$work/installed/$f" "$work/check/$f"; then
        echo "le candidat diffère du FIP installé sur $f — rien n'a été écrit" >&2
        exit 1
      fi
    done

    size="$(stat -c %s "$work/candidate.fip")"
    echo "écriture du BL33 mainline dans $disk (FIP $size octets, secteur 1)"
    dd if="$work/candidate.fip" of="$disk" bs=512 seek=1 conv=fsync,notrunc status=progress

    # Relecture depuis le média : ce que la ROM lira doit être ce qu'on a écrit.
    blocks="$(( (size + 511) / 512 ))"
    dd if="$disk" of="$work/reread.bin" bs=512 skip=1 count="$blocks" status=none
    if ! head -c "$size" "$work/reread.bin" | cmp -s - "$work/candidate.fip"; then
      echo "relecture du FIP différente de l'écrit" >&2
      exit 1
    fi

    echo "BL33 mainline écrit et relu ($(basename "$bl33"))."
    echo "sauvegarde : $prefix"
    echo "restauration du bootloader vendor :"
    echo "  zstd -dc $prefix | dd of=$disk bs=1M conv=fsync,notrunc"
  '';

  installScript = pkgs.writeShellScript "n5-install" ''
    set -euo pipefail

    target_system="${n5TargetSystem}"
    disk="''${1:-/dev/mmcblk1}"
    backup_dir="''${2:-/var/lib/n5-backup}"
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    work="$(mktemp -d /tmp/n5-install.XXXXXX)"

    if [ "''${EUID}" -ne 0 ]; then
      echo "run as root" >&2
      exit 1
    fi
    if [ ! -b "$disk" ]; then
      echo "not a block device: $disk" >&2
      exit 1
    fi

    p1="''${disk}p1"
    p2="''${disk}p2"
    if [ ! -b "$p1" ] || [ ! -b "$p2" ]; then
      echo "expected $p1 and $p2; refusing to repartition" >&2
      exit 1
    fi

    # Le FIP (secteur 1 → 1 Mio) et l'environnement du U-Boot vendor (628 Mio)
    # vivent avant p1 : aucune écriture ne doit les recouvrir, sauf le FIP
    # lui-même, explicitement, à la fin.
    start1="$(cat "/sys/class/block/$(basename "$p1")/start")"
    if [ "$start1" -lt 1368064 ]; then
      echo "$p1 starts before 668 MiB; vendor bootloader is not protected" >&2
      exit 1
    fi

    root_source="$(findmnt -n -o SOURCE /)"
    root_disk="$(lsblk -n -o PKNAME "$root_source" | head -n 1)"
    if [ "/dev/$root_disk" = "$disk" ]; then
      echo "refusing to install to the running disk $disk" >&2
      exit 1
    fi

    mkdir -p "$backup_dir"
    # Le préfixe de 668 Mio est presque entièrement vide : mesuré à 0,12 %
    # (668 Mio → 821 Kio). On ne demande donc que 64 Mio libres, et non 800.
    avail="$(df -Pm "$backup_dir" | tail -n 1 | tr -s ' ' | cut -d' ' -f4)"
    if [ "''${avail:-0}" -lt 64 ]; then
      echo "need at least 64 MiB free in $backup_dir" >&2
      exit 1
    fi

    echo "target: $disk (p1=$p1, p2=$p2)"
    echo "backup: $backup_dir"
    read -r -p "Type YES to overwrite p1/p2: " answer
    [ "$answer" = "YES" ] || exit 1

    cleanup() {
      umount /mnt/n5/boot 2>/dev/null || true
      umount /mnt/n5 2>/dev/null || true
      rm -rf "$work"
    }
    trap cleanup EXIT

    # 1. Sauvegarde AVANT toute écriture (préfixe + partitions boot).
    prefix="$backup_dir/prefix-668MiB-$stamp.img.zst"
    dd if="$disk" bs=1M count=668 status=none | zstd -T0 -3 -q -o "$prefix"
    zstd -t -q "$prefix"
    echo "sauvegarde : $prefix ($(stat -c %s "$prefix") octets)"
    for part in boot0 boot1; do
      if [ -b "''${disk}''${part}" ]; then
        dd if="''${disk}''${part}" of="$backup_dir/''${part}-$stamp.img" bs=1M status=progress
      fi
    done

    umount "$p1" 2>/dev/null || true
    umount "$p2" 2>/dev/null || true
    wipefs -a "$p1" "$p2"
    mkfs.vfat -F 32 -n NIXOS_BOOT "$p1"
    mkfs.ext4 -L "${n5TargetRootLabel}" "$p2"

    mkdir -p /mnt/n5
    mount "$p2" /mnt/n5
    mkdir -p /mnt/n5/boot
    mount -o rw "$p1" /mnt/n5/boot

    # 2. Système cible. `nixos-install` y joue `switch-to-configuration boot` :
    # la cible a `generic-extlinux-compatible`, donc `extlinux/extlinux.conf` et
    # les fichiers par génération atterrissent sur p1 — plus de charge utile à
    # plat, plus de `boot.scr`.
    nixos-install --root /mnt/n5 --system "$target_system" --no-root-passwd

    # L'étiquette posée sur p2 doit être celle que la cible attend dans son
    # fstab. Un écart ici donnerait un système installé qui ne trouve pas sa
    # racine au premier démarrage — précisément l'ambiguïté que l'on vient
    # supprimer entre une SD `NIXOS_SD` et la eMMC.
    fstab_label="$(awk '$2 == "/" { n = split($1, a, "/"); print a[n] }' /mnt/n5/etc/fstab)"
    if [ "$fstab_label" != "${n5TargetRootLabel}" ]; then
      echo "étiquette de racine : fstab='$fstab_label', attendu='${n5TargetRootLabel}'" >&2
      exit 1
    fi

    conf=/mnt/n5/boot/extlinux/extlinux.conf
    if [ ! -f "$conf" ]; then
      echo "extlinux.conf absent : la cible n'a pas écrit de chargeur" >&2
      exit 1
    fi
    grep -q '^  LINUX /nixos/' "$conf" || {
      echo "extlinux.conf sans LINUX /nixos/<génération>" >&2
      exit 1
    }
    grep -q '^  INITRD /nixos/' "$conf" || {
      echo "extlinux.conf sans INITRD /nixos/<génération>" >&2
      exit 1
    }
    if [ -e /mnt/n5/boot/boot.scr ]; then
      echo "boot.scr présent sur p1 : supprimé (le mainline le lirait avant extlinux)" >&2
      rm -f /mnt/n5/boot/boot.scr
    fi

    # Vérification de la FAT par relecture : `drop_caches` ne suffit pas tant
    # que la partition est montée, et il faut pousser au média avant de conclure.
    sync
    blockdev --flushbufs "$p1" 2>/dev/null || true
    umount /mnt/n5/boot
    mount -o ro "$p1" /mnt/n5/boot
    kernels="$(ls -1 /mnt/n5/boot/nixos 2>/dev/null | grep -c 'Image$' || true)"
    echo "extlinux installé : $kernels noyau(x) sous /boot/nixos"
    if [ "''${kernels:-0}" -lt 1 ]; then
      echo "aucun noyau sous /boot/nixos" >&2
      exit 1
    fi
    umount /mnt/n5/boot
    mount -o rw "$p1" /mnt/n5/boot

    # 3. BL33 : une seule implémentation de l'écriture, partagée avec le mode
    # autonome (`/etc/n5/uboot-install.sh`). On lui repasse l'horodatage pour
    # qu'il réutilise la sauvegarde faite à l'étape 1.
    ${ubootScript} "$disk" "$backup_dir" "$stamp"

    echo "retirer la carte SD puis démarrer sur la eMMC"
  '';
in
{
  image.fileName = lib.mkForce "nixelec-meson64-${config.hardware.nixbian.board}-installer.img";

  environment.systemPackages = with pkgs; [
    nixos-install-tools
    dosfstools
    e2fsprogs
    util-linux
    diffutils
    zstd
    gxlimg
  ];

  system.extraDependencies = [
    n5TargetSystem
    n5UbootBl33
  ];

  environment.etc."n5/install.sh".source = installScript;
  # Remplacement du seul BL33, sans reformater : utilisable sur une carte déjà
  # installée (essai d'un chargeur, retour arrière).
  environment.etc."n5/uboot-install.sh".source = ubootScript;

  services.getty.autologinUser = lib.mkForce "root";
  systemd.services."serial-getty@ttyAML0".enable = true;
}
