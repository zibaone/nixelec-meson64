{
  config,
  lib,
  options,
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
  imports = [
    ../system/minimal.nix
    ../system/vdec-firmware.nix
  ];

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

      # L'AIU achemine son PCM vers le HDMI, l'ACODEC ou le SPDIF par un
      # sélecteur de mixer, `AIU HDMI CTRL SRC`, qui vaut DISABLED au boot.
      # Tant qu'il n'est pas sur I2S, le flux part vers l'ACODEC analogique :
      # le HDMI reste muet alors que la carte son, le codec HDMI et son ELD
      # sont présents et que le graphe DAPM est entièrement alimenté.
      # Mesuré sur Magicsee N5 le 2026-10-29 : `eld#2` identifie la TV, les
      # widgets « AIU HDMI I2S IN », « HDMITX I2S Playback » et « HDMITX TX »
      # sont On, le PCM tourne — seul ce sélecteur était faux. Un `softdep`
      # sur la carte avait été tenté la veille : inopérant (ordre de
      # chargement inchangé, et `modprobe --show-depends` ne le liste pas).
      systemd.services.meson-hdmi-audio-route = {
        description = "Router le PCM de l'AIU vers le bloc HDMI";
        wantedBy = [ "multi-user.target" ];
        after = [ "sound.target" ];
        before = [ "kodi.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        # Boucle bornée : la carte peut apparaître après le démarrage du
        # service, `amixer cset` échoue tant qu'elle n'est pas enregistrée.
        script = ''
          i=0
          while [ "$i" -lt 20 ]; do
            ${pkgs.alsa-utils}/bin/amixer -c 0 cset name='AIU HDMI CTRL SRC' I2S && exit 0
            i=$((i + 1))
            sleep 0.5
          done
          echo "AIU HDMI CTRL SRC introuvable : routage HDMI non appliqué" >&2
          exit 1
        '';
      };

      boot.loader.generic-extlinux-compatible.configurationLimit = lib.mkDefault 0;

      hardware.graphics.enable = lib.mkDefault false;

      # Microcodes du VPU Amlogic : côté carte, comme le mode vidéo. Sans eux,
      # DRMPRIME sélectionne bien le VPU mais chaque paquet est rejeté côté
      # application (`Invalid data found when processing input`).
      nixelec.vdecFirmware.enable = lib.mkDefault true;
    }

    # Faits GXL pour la couche kiosque (`nixelec-kiosk`), publiés uniquement
    # quand elle est importée : `nixelec.platform` n'existe pas sur une image
    # nue. Ce sont des FAITS : la carte ne pose jamais `nixelec.kiosk.*`.
    #
    # Mesuré sur le Magicsee N5 : CEC du bloc AO (`cec-meson-ao`), connecteur
    # `HDMI-A-1`, mode 1080p60 en préférence (jamais `D`). Aucun watchdog
    # matériel prouvé sur cette carte : `enable = false` est un fait négatif,
    # pas un oubli — un watchdog non prouvé ne protège de rien.
    (lib.optionalAttrs (options ? nixelec.platform) {
      nixelec.platform = {
        cecDriver = lib.mkDefault "cec-meson-ao";
        hdmiConnector = lib.mkDefault "HDMI-A-1";
        videoMode = lib.mkDefault "1920x1080@60";
        watchdog = {
          enable = lib.mkDefault false;
          maxTimeout = lib.mkDefault null;
        };
      };
    })

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
