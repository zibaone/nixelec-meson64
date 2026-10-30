{
  config,
  lib,
  pkgs,
  n5TargetSystem,
  n5TargetKernel,
  n5TargetDtb,
  n5TargetBootParams,
  ...
}:

let
  targetBoot = (import ./n5-boot.nix { inherit pkgs lib; }).mkBootFiles {
    kernel = n5TargetKernel;
    initrd = "${n5TargetSystem}/initrd";
    dtbName = n5TargetDtb;
    rootLabel = "NIXOS_SD";
    bootParams = n5TargetBootParams;
    toplevel = n5TargetSystem;
  };

  installScript = pkgs.writeShellScript "n5-install" ''
    set -euo pipefail

    target_system="${n5TargetSystem}"
    target_boot="${targetBoot}"
    disk="''${1:-/dev/mmcblk1}"
    backup_dir="''${2:-/var/lib/n5-backup}"

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
    avail="$(df -Pm "$backup_dir" | tail -n 1 | tr -s ' ' | cut -d' ' -f4)"
    if [ "''${avail:-0}" -lt 800 ]; then
      echo "need at least 800 MiB free in $backup_dir" >&2
      exit 1
    fi

    echo "target: $disk (p1=$p1, p2=$p2)"
    echo "backup: $backup_dir"
    read -r -p "Type YES to overwrite p1/p2: " answer
    [ "$answer" = "YES" ] || exit 1

    dd if="$disk" of="$backup_dir/prefix-668MiB.img" bs=1M count=668 status=progress
    for part in boot0 boot1; do
      if [ -b "''${disk}''${part}" ]; then
        dd if="''${disk}''${part}" of="$backup_dir/''${part}.img" bs=1M status=progress
      fi
    done

    umount "$p1" 2>/dev/null || true
    umount "$p2" 2>/dev/null || true
    wipefs -a "$p1" "$p2"
    mkfs.vfat -F 32 -n NIXOS_BOOT "$p1"
    mkfs.ext4 -L NIXOS_SD "$p2"

    mkdir -p /mnt/n5
    mount "$p2" /mnt/n5
    mkdir -p /mnt/n5/boot
    mount -o rw "$p1" /mnt/n5/boot
    cleanup() {
      umount /mnt/n5/boot 2>/dev/null || true
      umount /mnt/n5 2>/dev/null || true
    }
    trap cleanup EXIT

    nixos-install --root /mnt/n5 --system "$target_system" --no-root-passwd

    # Copie de la charge utile, puis vérification octet par octet.
    # Deux pièges mesurés sur la carte le 30/10 :
    #  - `drop_caches` ne suffit pas tant que la FAT est montée : les pages de
    #    l'inode restent référencées, la comparaison lit le cache d'écriture et
    #    valide une copie fausse. Il faut démonter puis remonter en lecture seule.
    #  - l'écriture doit être poussée au média (`blockdev --flushbufs`) avant de
    #    conclure, sinon un `uImage.multi` — dernier fichier écrit — peut rester
    #    absent du support alors que tout semble conforme.
    copy_payload() {
      local f b
      for f in "$target_boot"/*; do
        b="$(basename "$f")"
        rm -f "/mnt/n5/boot/$b"
        cp "$f" "/mnt/n5/boot/$b"
      done
    }

    verify_payload() {
      local f b bad=0
      sync
      blockdev --flushbufs "$p1" 2>/dev/null || true
      umount /mnt/n5/boot 2>/dev/null || true
      mount -o ro "$p1" /mnt/n5/boot
      for f in "$target_boot"/*; do
        b="$(basename "$f")"
        if ! cmp -s "$f" "/mnt/n5/boot/$b"; then
          echo "  $b diffère du store" >&2
          bad=1
        fi
      done
      umount /mnt/n5/boot
      mount -o rw "$p1" /mnt/n5/boot
      return "$bad"
    }

    copy_payload
    if ! verify_payload; then
      echo "nouvelle copie après écart constaté" >&2
      copy_payload
      if ! verify_payload; then
        echo "charge utile d'amorçage corrompue sur $p1 — installation interrompue" >&2
        echo "la carte ne démarrerait pas ; relancer l'installation" >&2
        exit 1
      fi
    fi
    echo "charge utile vérifiée : $(ls -1 /mnt/n5/boot | wc -l) fichiers"

    echo "installed; remove the SD card and boot from eMMC"
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
  ];

  system.extraDependencies = [
    n5TargetSystem
    targetBoot
  ];

  environment.etc."n5/install.sh".source = installScript;
  environment.etc."n5/target-boot".source = targetBoot;

  services.getty.autologinUser = lib.mkForce "root";
  systemd.services."serial-getty@ttyAML0".enable = true;
}
