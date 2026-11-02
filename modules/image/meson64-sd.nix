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
    # Chemin complet : le paquet porte les overlays de la carte.
    dtb = "${config.hardware.deviceTree.package}/${config.hardware.deviceTree.name}";
    dtbName = config.hardware.deviceTree.name;
    rootLabel = config.nixelec.rootLabel;
    bootParams = config.boot.kernelParams;
    toplevel = config.system.build.toplevel;
  };
in
{
  imports = [ (modulesPath + "/installer/sd-card/sd-image.nix") ];

  # Une image SD est sa propre racine : c'est son étiquette (celle que crée
  # `sd-image.nix`) qui doit figurer dans les `root=` du payload et de
  # l'extlinux. La cible eMMC, elle, garde `NIXOS_EMMC` (défaut de l'option).
  nixelec.rootLabel = lib.mkDefault config.sdImage.rootVolumeLabel;

  boot.loader.grub.enable = lib.mkForce false;
  boot.loader.generic-extlinux-compatible.enable = lib.mkForce false;

  image.fileName = lib.mkDefault "nixelec-meson64-${config.hardware.nixbian.board}.img";

  sdImage = {
    firmwarePartitionOffset = lib.mkDefault 1;
    # 512 Mio était très au-dessus du besoin : la charge utile fait ~127 Mo
    # décimaux (~121 Mio) — `Image` 38, `uImage` 38, `initrd` 25, `uInitrd` 25,
    # DTB 41 Ko (les deux formes noyau/initrd cohabitent : brute pour uEnv/extlinux,
    # encapsulée uImage pour l'autoscript). L'ancien conteneur `-T multi`
    # (63,5 Mo) n'est plus produit. Sur les supports de 4 Go réels (3,73 Gio
    # utiles), ces 256 Mio sont la différence entre une image qui tient et une
    # qui ne tient pas.
    firmwareSize = lib.mkDefault 256;
    firmwarePartitionName = lib.mkDefault "NIXOS_BOOT";
    compressImage = lib.mkDefault true;

    populateFirmwareCommands = ''
      mkdir -p firmware/extlinux
      # -r : `extlinux/` est un dossier ; sans lui le mainline ne peut pas
      # démarrer cette carte (cf. n5-boot.nix).
      cp -rL ${bootFiles}/. firmware/
    '';

    populateRootCommands = "";
  };
}
