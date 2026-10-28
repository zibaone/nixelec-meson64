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

  crossKernel =
    extraConfig:
    let
      patchDir = inputs.nixbian.outPath + "/metadata/nix/patches/kernel/meson64-vdec-7.0";
    in
    if !(builtins.pathExists patchDir) then
      null
    else
      let
        buildPkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
        crossPkgs = buildPkgs.pkgsCross.aarch64-multiplatform;
        helpers = import (inputs.nixbian.outPath + "/metadata/nix/library.nix") {
          pkgs = crossPkgs;
        };
        platforms = import (inputs.nixbian.outPath + "/metadata/nix/families/meson64/platforms.nix");
        base = platforms."meson64-edge";
        kernelSrc = inputs.nixbian.legacyPackages.x86_64-linux.meson64.kernelSrcs.meson64-edge;
        meta = base // {
          linux_family = "meson64";
          family = "meson64";
          kernel = base.kernel // {
            src = kernelSrc;
          };
        };
        patchNames = builtins.filter (name: builtins.match ".*\\.patch" name != null) (
          builtins.attrNames (builtins.readDir patchDir)
        );
      in
      helpers.buildKernel {
        inherit meta extraConfig;
        extraPatches = map (name: patchDir + "/" + name) patchNames;
        dtb_list = [ "amlogic/meson-gxl-s905x-p212.dtb" ];
        configMode = "armbian";
      };
in
{
  flake.nixosModules = {
    sd-image = ../modules/image/meson64-sd.nix;

    installer = ../modules/image/meson64-installer.nix;

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
      let
        kernel = crossKernel config.nixelec.vpu.config;
      in
      {
        imports = [
          inputs.nixbian.nixosModules.nixbian
          ../modules/family/meson64.nix
          ../modules/boards/magicsee-n5.nix
        ];

        nixelec.kernelPackage = lib.mkForce (
          if kernel != null then
            kernel
          else
            lib.warn "nixelec: le pin nixbian ne contient pas les patchs meson64-vdec-7.0; repli sur le noyau par carte" null
        );

        hardware.nixbian.kernelModules.prune = lib.mkForce false;

        system.modulesTree =
          let
            nixbianLib = import (inputs.nixbian.outPath + "/metadata/nix/library.nix") {
              inherit pkgs;
            };
            prunedModules = nixbianLib.pruneKernelModules {
              name = "linux-modules-${config.hardware.nixbian.board}-pruned";
              kernelOut = config.boot.kernelPackages.kernel;
              modules = config.boot.kernelPackages.kernel.modules;
              dtb = "${config.boot.kernelPackages.kernel}/dtbs/${config.hardware.deviceTree.name}";
              extraKeep = config.hardware.nixbian.kernelModules.extraKeep ++ config.boot.kernelModules;
              extraKeepPaths = config.boot.extraModulePackages;
            };
          in
          lib.mkForce ([ prunedModules ] ++ config.boot.extraModulePackages);
      };
  };
}
