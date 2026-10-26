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

  nixelec.kernelPackage = lib.mkForce null;

  boot.kernelParams = [ "cma=256M" ];
}
