# Charge utile d'amorçage Amlogic, réécrite à chaque activation.
#
# Le vendor U-Boot de l'Amlogic ne lit pas `extlinux.conf` : `boot.scr` charge
# un `uImage.multi` (noyau + initrd) et le DTB depuis la première partition, et
# porte `init=<toplevel>` **dans ses bootargs**. Résultat : `nixos-rebuild
# switch` mettait bien `/run/current-system` à jour, mais au reboot la carte
# repartait sur le système gravé dans l'image — `nixos-rebuild` le signalait
# par « do not know how to make this configuration bootable ».
#
# Ce module reconstruit la charge utile à partir du système **courant** et la
# recopie dans la partition NIXOS_BOOT pendant l'activation. `init=` suit donc
# le déploiement, et un changement de noyau survit au reboot.
#
# La construction réutilise `mkBootFiles` (le même code que l'image) : une
# seule définition de la ligne de commande et du script U-Boot, donc aucune
# divergence possible entre l'image et le déploiement.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.nixelec.meson64.bootPayload;

  rootLabel =
    if config.sdImage.rootVolumeLabel or null != null then
      config.sdImage.rootVolumeLabel
    else
      "NIXOS_SD";

  bootFiles = (import ../image/n5-boot.nix { inherit pkgs lib; }).mkBootFiles {
    kernel = config.boot.kernelPackages.kernel;
    initrd = "${config.system.build.toplevel}/initrd";
    dtbName = config.hardware.deviceTree.name;
    rootLabel = rootLabel;
    bootParams = config.boot.kernelParams;
    toplevel = config.system.build.toplevel;
  };
in
{
  options.nixelec.meson64.bootPayload = {
    enable = lib.mkEnableOption "réécrire la charge utile d'amorçage à chaque activation";

    device = lib.mkOption {
      type = lib.types.str;
      default = "/dev/disk/by-label/NIXOS_BOOT";
      description = ''
        Partition de démarrage vue par le vendor U-Boot (première partition,
        vfat, étiquette `NIXOS_BOOT`). Le montage est refusé silencieusement si
        elle est absente : une activation ne doit jamais échouer sur ce point.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # `ubootTools` n'est pas requis à l'exécution : `mkimage` tourne à la
    # construction, l'activation ne fait que copier des fichiers.
    system.activationScripts.meson64BootPayload = lib.stringAfter [ "etc" ] ''
      if [ -b "${cfg.device}" ]; then
        mnt=$(${pkgs.coreutils}/bin/mktemp -d)
        if ${pkgs.util-linux}/bin/mount -t vfat -o rw "${cfg.device}" "$mnt"; then
          # Copie explicite : la partition peut aussi porter des fichiers du
          # vendor (bootloader) qu'il ne faut pas toucher.
          for f in uImage.multi boot.scr uEnv.ini; do
            ${pkgs.coreutils}/bin/cp -f "${bootFiles}/$f" "$mnt/$f"
          done
          for f in "${bootFiles}"/*.dtb; do
            ${pkgs.coreutils}/bin/cp -f "$f" "$mnt/"
          done
          ${pkgs.coreutils}/bin/sync
          ${pkgs.util-linux}/bin/umount "$mnt"
          echo "meson64-boot: charge utile d'amorçage réécrite depuis ${config.system.build.toplevel}"
        else
          echo "meson64-boot: ${cfg.device} illisible, amorçage laissé tel quel" >&2
        fi
        ${pkgs.coreutils}/bin/rmdir "$mnt"
      fi
    '';
  };
}
