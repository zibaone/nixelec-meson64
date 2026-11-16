{ inputs, ... }:

let
  # Modèle B (2026-11-16) : la couche famille construit le noyau à partir de
  # l'export Armbian vanilla de nixbian et de ses propres patches VDEC. Le
  # chemin est local à cette couche, pas dans `nixbian` (qui n'en porte plus).
  crossKernel =
    extraConfig:
    let
      patchDir = ../patches/kernel/meson64-vdec-7.0;
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

    # Contrats communs (nixelec-common). Le client WPA est le seul contrat de
    # provisioning ; le pilote ath10k ci-dessous ne fait plus que le firmware
    # et les modules noyau. Les modules IR, afficheur et racine eMMC sont
    # ré-exportés pour que les deux familles aient la même surface ; ils sont
    # inertes tant qu'aucune configuration de carte ne les active.
    wifi-client = inputs.nixelec-common.nixosModules.wifi-client;
    ir = inputs.nixelec-common.nixosModules.ir;
    front-panel = inputs.nixelec-common.nixosModules.front-panel;
    emmc-root = inputs.nixelec-common.nixosModules.emmc-root;

    # Image de qualification VPU : ajoute v4l-utils + ffmpeg v4l2-request.
    # Séparée de l'image minimale pour que la cible de bring-up reste nue.
    decode-tools =
      { pkgs, ... }:
      let
        hostPkgs = import inputs.nixpkgs { system = "x86_64-linux"; };
      in
      {
        imports = [ ../modules/system/decode-tools.nix ];

        nixelec.decodeTools = {
          enable = true;
          ffmpeg = inputs.v4l2request.packages.${pkgs.stdenv.hostPlatform.system}.ffmpeg-v4l2request;
          sampleEncoder = hostPkgs.ffmpeg;
        };
      };

    # WiFi QCA9377 (ath10k_sdio) : la carte n'ajoute que le pilote, le firmware
    # et le shim `nixelec.wifi` ; le client WPA vient de nixelec-common.
    wifi-ath10k = {
      imports = [
        inputs.nixelec-common.nixosModules.wifi-client
        ../modules/services/wifi-ath10k.nix
      ];
    };

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

        nixelec.kernelPackage = lib.mkDefault (crossKernel "");
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
