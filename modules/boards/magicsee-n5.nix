{
  config,
  lib,
  ...
}:

{
  hardware.nixbian = {
    board = lib.mkDefault "aml-s9xx-box";
    kernelVendor = lib.mkDefault "edge";
  };

  hardware.deviceTree.name = lib.mkForce "amlogic/meson-gxl-s905x-p212.dtb";

  boot.loader.grub.enable = lib.mkForce false;
  boot.loader.generic-extlinux-compatible.enable = lib.mkForce false;

  boot.kernelParams = lib.mkForce [
    "console=ttyAML0,115200n8"
    "cma=256M"
  ];
}
