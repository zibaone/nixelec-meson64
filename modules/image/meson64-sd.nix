{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

let
  bootFiles = (import ./n5-boot.nix { inherit pkgs lib; }).mkBootFiles {
    kernel = config.boot.kernelPackages.kernel;
    initrd = "${config.system.build.toplevel}/initrd";
    dtbName = config.hardware.deviceTree.name;
    rootLabel = config.sdImage.rootVolumeLabel;
    bootParams = config.boot.kernelParams;
    toplevel = config.system.build.toplevel;
  };
in
{
  imports = [ (modulesPath + "/installer/sd-card/sd-image.nix") ];

  boot.loader.grub.enable = lib.mkForce false;
  boot.loader.generic-extlinux-compatible.enable = lib.mkForce false;

  image.fileName = lib.mkDefault "nixelec-meson64-${config.hardware.nixbian.board}.img";

  sdImage = {
    firmwarePartitionOffset = lib.mkDefault 1;
    # 512 Mio était très au-dessus du besoin : la charge utile fait ~130 Mio
    # (uImage 36, uInitrd 24, uImage.multi 60, DTB). Sur les supports de 4 Go
    # réels (3,73 Gio utiles), ces 256 Mio sont la différence entre une image
    # qui tient et une qui ne tient pas.
    firmwareSize = lib.mkDefault 256;
    firmwarePartitionName = lib.mkDefault "NIXOS_BOOT";
    compressImage = lib.mkDefault true;

    populateFirmwareCommands = ''
      cp -L ${bootFiles}/* firmware/
    '';

    populateRootCommands = "";
  };
}
