{ inputs, ... }:

let
  familyKernel =
    { config, pkgs, ... }:
    let
      system = pkgs.stdenv.hostPlatform.system;
      key = "meson64-${config.hardware.nixbian.kernelVendor}";
      legacy = inputs.nixbian.legacyPackages.${system} or { };
      familyPackages = legacy.meson64 or { };
      kernels = familyPackages.kernels or { };
    in
    if builtins.hasAttr key kernels then
      kernels.${key}
    else
      throw ''
        nixelec: nixbian does not expose legacyPackages.${system}.meson64.kernels.${key}.
        Check the nixbian input and hardware.nixbian.kernelVendor.
      '';
in
{
  flake.nixosModules = {
    meson64 =
      {
        config,
        lib,
        pkgs,
        ...
      }:
      {
        imports = [
          inputs.nixbian.nixosModules.nixbian
          ../modules/family/meson64.nix
        ];

        nixelec.kernelPackage = lib.mkDefault (familyKernel {
          inherit config pkgs;
        });
      };

    magicsee-n5 =
      {
        config,
        lib,
        pkgs,
        ...
      }:
      {
        imports = [
          inputs.nixbian.nixosModules.nixbian
          ../modules/family/meson64.nix
          ../modules/boards/magicsee-n5.nix
        ];

        nixelec.kernelPackage = lib.mkDefault (familyKernel {
          inherit config pkgs;
        });
      };
  };
}
