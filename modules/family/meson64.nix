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
  imports = [ ../system/minimal.nix ];

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

      environment.etc."sysctl.d/55-nixos-aslr-entropy.conf".source = lib.mkForce (
        pkgs.writeText "55-nixos-aslr-entropy.conf" ""
      );

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

      # The modules tree is force-replaced by a pruned one (parts/modules.nix),
      # so anything a service modprobes must be listed here or the module is
      # absent. "zram" is required by nixbian's SD wear mitigation
      # (zramSwap.enable, nix/parts/nixos-module.nix): without it
      # dev-zram0.swap waits, times out every 90 s and floods the console.
      hardware.nixbian.kernelModules.extraKeep = [
        "zram"
        "meson_ir"
        "cec-meson-ao"
        "dw-hdmi-i2s-audio"
        "snd-soc-hdmi-codec"
        "lima"
        # L'élagage est deny-by-default et ne suit que les alias `of:` du DTB.
        # Le QCA9377 est un périphérique SDIO sans nœud `compatible` dans le
        # DTB p212 : sans cette entrée, tout `drivers/net/wireless/` disparaît
        # et `modprobe ath10k_sdio` répond « Module not found » alors que le
        # module est compilé. La fermeture embarque ath10k_core, mac80211,
        # cfg80211, ath, rfkill et libarc4.
        "ath10k_sdio"
        # Même classe de défaut pour les décodeurs rc-core : ils n'ont aucun
        # compatible OF, donc ils tombent aussi. `nec` est le protocole des
        # télécommandes Amlogic ; les autres se décommentent au besoin.
        "ir_nec_decoder"
      ];

      # La carte son (`gx-sound-card`) crée un PCM par dai-link du DT, mais
      # seulement pour les liens dont le codec est déjà enregistré au moment de
      # sa sonde. La carte et le codec HDMI sont deux modules indépendants :
      # sans ordre imposé, la carte se sonde la première, le lien HDMI n'est
      # jamais exposé et il ne reste que `fe.dai-link-0` (l'ACODEC analogique).
      # Mesuré le 2026-10-28 : PCM du HDMI absent, tous les contrôles du mixer
      # en `ACODEC*`, aucun son sur la TV. `softdep` force le codec avant.
      # Priorité normale, pas `mkDefault` : un autre module définit cette
      # option à priorité 100 avec une chaîne vide, et une définition plus
      # faible est alors écrasée en silence (vérifié : mkDefault rendait "").
      # À priorité égale, les chaînes se concatènent.
      boot.extraModprobeConfig = ''
        softdep snd_soc_meson_gx_sound_card pre: snd_soc_hdmi_codec snd_soc_meson_aiu
      '';

      boot.loader.generic-extlinux-compatible.configurationLimit = lib.mkDefault 0;

      hardware.graphics.enable = lib.mkDefault false;
    }

    (lib.mkIf cfg.vpu.enable {
      hardware.nixbian.kernelModules.extraKeep = [ "meson-amvdec" ];
      boot.kernelModules = [ "meson-amvdec" ];
    })

    (lib.mkIf (cfg.vpu.enable && cfg.kernelPackage == null) {
      hardware.nixbian.extraPatches = cfg.vpu.patches;
      hardware.nixbian.extraConfig = cfg.vpu.config;
    })
  ];
}
