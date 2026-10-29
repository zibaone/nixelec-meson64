{
  config,
  lib,
  ...
}:

{
  imports = [ ../system/boot-payload.nix ];

  # Le vendor U-Boot de cette carte ne lit pas extlinux.conf : il charge
  # `uImage.multi` + un DTB depuis la première partition, avec `init=` figé dans
  # les bootargs de `boot.scr`. Sans ce module, chaque `nixos-rebuild switch`
  # était perdu au reboot (« do not know how to make this configuration
  # bootable ») ; avec lui, la charge utile suit l'activation.
  nixelec.meson64.bootPayload.enable = lib.mkDefault true;

  hardware.nixbian = {
    board = lib.mkDefault "aml-s9xx-box";
    kernelVendor = lib.mkDefault "edge";
  };

  hardware.deviceTree.name = lib.mkForce "amlogic/meson-gxl-s905x-p212.dtb";

  # VPU stateless meson-amvdec : c'est une capacité de la carte, pas du
  # lecteur. Sans elle, DRMPRIME n'a pas de décodeur à sélectionner et Kodi
  # décode en CPU sans le dire.
  nixelec.vpu.enable = lib.mkDefault true;

  boot.loader.grub.enable = lib.mkForce false;
  boot.loader.generic-extlinux-compatible.enable = lib.mkForce false;

  boot.kernelParams = lib.mkForce [
    "console=ttyAML0,115200n8"
    "cma=256M"
    # Sortie HDMI : mode préféré, jamais forcé (`D`). L'EDID d'un téléviseur
    # annonce du 4K que GXL ne compose pas ; panfrost/lima n'y sont pour rien.
    # Côté carte, parce que c'est un fait du boîtier (et non du lecteur).
    "video=HDMI-A-1:1920x1080@60"
  ];
}
