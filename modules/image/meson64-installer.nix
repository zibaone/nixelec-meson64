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
    mount "$p1" /mnt/n5/boot
    cleanup() {
      umount /mnt/n5/boot 2>/dev/null || true
      umount /mnt/n5 2>/dev/null || true
    }
    trap cleanup EXIT

    nixos-install --root /mnt/n5 --system "$target_system" --no-root-passwd
    cp -r "$target_boot"/. /mnt/n5/boot/
    sync

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
