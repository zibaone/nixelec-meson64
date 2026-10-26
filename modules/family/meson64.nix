{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.nixelec;

  vdecPatchesDir = ../../patches/kernel/meson64-vdec-7.0;
  vdecPatchNames = builtins.filter (name: lib.hasSuffix ".patch" name) (
    builtins.attrNames (builtins.readDir vdecPatchesDir)
  );
  vdecPatches = map (name: vdecPatchesDir + "/${name}") vdecPatchNames;
in
{
  options.nixelec.kernelPackage = lib.mkOption {
    type = lib.types.nullOr lib.types.package;
    default = null;
    description = ''
      Kernel to use. `null` lets nixbian build the per-board kernel
      (buildKernel + board patches). A nixbian family package reproduces
      the reference deployment and shares its store paths.
    '';
  };

  options.nixelec.vpu = {
    enable = lib.mkEnableOption "Amlogic meson-amvdec stateless VPU";

    patches = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = vdecPatches;
      description = "Kernel patches for the stateless meson-amvdec driver.";
    };

    config = lib.mkOption {
      type = lib.types.str;
      default = ''
        # CONFIG_VIDEO_MESON_VDEC is not set
        CONFIG_VIDEO_MESON_AMVDEC=m
        CONFIG_MEDIA_SUPPORT=m
        CONFIG_MEDIA_CONTROLLER=y
        CONFIG_VIDEO_DEV=m
        CONFIG_V4L2_MEM2MEM_DEV=m
        CONFIG_VIDEOBUF2_DMA_CONTIG=m
        CONFIG_V4L2_H264=m
        CONFIG_MESON_CANVAS=m
      '';
      description = "Kernel configuration fragment for the stateless VPU.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (cfg.kernelPackage != null) {
      boot.kernelPackages = lib.mkForce (pkgs.linuxPackagesFor cfg.kernelPackage);
    })

    {
      hardware.nixbian = {
        enable = lib.mkDefault true;
        family = lib.mkDefault "meson64";
        kernelVendor = lib.mkDefault "edge";
        configMode = lib.mkDefault "armbian";
      };

      boot.consoleLogLevel = lib.mkDefault 7;
      boot.kernelParams = lib.mkDefault [ "console=ttyAML0,115200n8" ];

      boot.initrd.includeDefaultModules = false;
      boot.initrd.availableKernelModules = lib.mkForce [
        "mmc_block"
        "meson_gx_mmc"
        "ext4"
        "vfat"
      ];

      boot.kernelModules = [
        "meson_ir"
        "cec-meson-ao"
        "dw-hdmi-i2s-audio"
        "snd-soc-hdmi-codec"
        "lima"
      ];

      hardware.nixbian.kernelModules.extraKeep = [
        "meson_ir"
        "cec-meson-ao"
        "dw-hdmi-i2s-audio"
        "snd-soc-hdmi-codec"
        "lima"
      ];

      boot.loader.generic-extlinux-compatible.configurationLimit = lib.mkDefault 0;

      hardware.graphics.enable = lib.mkDefault true;
    }

    (lib.mkIf cfg.vpu.enable {
      hardware.nixbian.extraPatches = cfg.vpu.patches;
      hardware.nixbian.extraConfig = cfg.vpu.config;
      hardware.nixbian.kernelModules.extraKeep = [ "meson-amvdec" ];
      boot.kernelModules = [ "meson-amvdec" ];
    })
  ];
}
