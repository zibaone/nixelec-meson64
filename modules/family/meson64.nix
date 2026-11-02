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

  # Étiquette de la racine. Une eMMC et une carte SD NixOS se démarrent avec la
  # même image : si les deux portent la même étiquette, `/dev/disk/by-label/…`
  # (et donc stage-1) choisit le premier disque énuméré, c'est-à-dire la SD.
  # Deux étiquettes distinctes rendent le montage déterministe.
  options.nixelec.rootLabel = lib.mkOption {
    type = lib.types.str;
    default = "NIXOS_EMMC";
    description = ''
      Étiquette de la partition racine du système installé. Les images SD
      l'écrasent avec leur `sdImage.rootVolumeLabel` (`NIXOS_SD` par défaut,
      `N5_INSTALL` pour l'installateur), pour qu'une carte SD insérée ne puisse
      pas être prise pour la racine de la eMMC.
    '';
  };

  # Schéma d'amorçage de l'**unité**, pas de la carte : la même N5 peut être
  # restée sur son U-Boot vendor ou avoir reçu le BL33 mainline. Le
  # discriminant est donc l'état du chargeur, et c'est la configuration cible
  # qui le déclare.
  #
  # L'option porte **ensemble** les trois pièces qui doivent rester cohérentes :
  #   - `boot.loader.generic-extlinux-compatible` (qui écrit `extlinux.conf` et
  #     les générations sous `/boot/nixos`) ;
  #   - le montage de `NIXOS_BOOT` sur `/boot` — sans lui, `switch` écrit dans
  #     l'ext4 et la FAT garde l'entrée du dernier `dd` ;
  #   - la forme de la charge utile : épinglée (`uImage`/`uInitrd`/autoscripts/
  #     `uEnv.ini`) pour vendor, aucune pour mainline. Cette troisième pièce est
  #     appliquée là où la charge utile naît — la branche vendor de
  #     `install.sh` pour une unité nue, `nixos-install` pour une unité
  #     mainline —, pas ici : `mkBootFiles` reste la source unique des deux
  #     formes, et une image SD doit rester démarrable par les deux chargeurs.
  #
  # Défaut `vendor` : une configuration qui ne désigne pas explicitement son
  # unité ne doit **jamais** faire écrire le secteur 1 (FIP) ni supprimer
  # `boot.scr` sur une carte qu'on n'a pas désignée. `mainline` se pose par
  # hôte (`nixelec.bootloader = "mainline"`), et seulement sur une unité dont
  # le passage au BL33 a été fait.
  options.nixelec.bootloader = lib.mkOption {
    type = lib.types.enum [
      "vendor"
      "mainline"
    ];
    default = "vendor";
    description = ''
      Schéma d'amorçage de l'unité : `vendor` (U-Boot d'origine, charge utile
      épinglée sur `NIXOS_BOOT`) ou `mainline` (BL33 U-Boot, `extlinux.conf`
      écrit par chaque génération, `NIXOS_BOOT` monté sur `/boot`).

      Les deux ne cohabitent pas sur une carte : l'installateur refuse un
      schéma différent de celui déclaré ici, avant la première écriture.
    '';
  };

  options.nixelec.vpu = {
    enable = lib.mkEnableOption "Amlogic meson VPU";

    mode = lib.mkOption {
      type = lib.types.enum [
        "stateful"
        "stateless"
      ];
      default = "stateless";
      description = ''
        Which kernel driver claims the VPU.

        `stateful` builds the staging `meson-vdec` (V4L2 M2M, decoded by
        `h264_v4l2m2m` in stock FFmpeg). `stateless` builds `meson-amvdec`
        (LibreELEC backport, V4L2 Request API) consumed by the patched FFmpeg of
        `nix-v4l2-request`.

        Both drivers claim the same compatible, so exactly one is built.

        Measured on the N5 (S905L, 7.0.14) on 2026-10-30, 300 frames of
        1080p30: stateless decodes H.264, HEVC and HEVC 10-bit with 0 decode
        errors for about 1 s of CPU per 10 s of video, against 19 s (H.264) and
        48 s (HEVC) in software. Stateful decodes H.264 too but spends 8 s in
        kernel time copying planes, and Kodi cannot render it without the
        `v4l2-drmprime` patch (which has no FFmpeg 6 port). `stateless` is
        therefore the default; `stateful` stays selectable as a fallback and
        for measurements.
      '';
    };

    kernelModule = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = if cfg.vpu.mode == "stateful" then "meson-vdec" else "meson-amvdec";
      description = "Kernel module to load for the selected mode.";
    };

    patches = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = vdecPatches;
      description = "Kernel patches for the stateless meson-amvdec driver.";
    };

    config = lib.mkOption {
      type = lib.types.str;
      default =
        if cfg.vpu.mode == "stateful" then
          ''
            CONFIG_VIDEO_MESON_VDEC=m
            # CONFIG_VIDEO_MESON_AMVDEC is not set
            CONFIG_MEDIA_SUPPORT=m
            CONFIG_MEDIA_CONTROLLER=y
            CONFIG_VIDEO_DEV=m
            CONFIG_V4L2_MEM2MEM_DEV=m
            CONFIG_VIDEOBUF2_DMA_CONTIG=m
            CONFIG_V4L2_H264=m
            CONFIG_MESON_CANVAS=m
          ''
        else
          ''
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
      description = "Kernel configuration fragment for the selected VPU mode.";
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (cfg.kernelPackage != null) {
      boot.kernelPackages = lib.mkForce (pkgs.linuxPackagesFor cfg.kernelPackage);
    })

    # Les trois pièces du schéma, ensemble. `mkDefault` : un hôte peut encore
    # poser une priorité supérieure, mais il ne peut pas hériter d'un mélange
    # silencieux (extlinux sans montage, ou montage sans extlinux).
    (lib.mkIf (cfg.bootloader == "mainline") {
      boot.loader.generic-extlinux-compatible.enable = lib.mkDefault true;

      # p1 fait 488 Mio et chaque génération y coûte noyau + initrd (~63 Mo,
      # mesurés : Image 38,4 Mio, initrd 24,0 Mio). Sans limite, la septième
      # reconstruction remplit la partition et `nixos-rebuild` échoue en pleine
      # écriture. Trois générations = ~190 Mo, avec de la marge pour le reste.
      boot.loader.generic-extlinux-compatible.configurationLimit = lib.mkDefault 3;

      # Sans ce montage, `switch` écrit `extlinux.conf` et les générations dans
      # l'ext4 de la racine : la FAT garde l'entrée du dernier `dd` et le
      # chargeur ne suit plus les générations. C'est le maillon qui rend le
      # mainline « où `switch` suffit ».
      fileSystems."/boot" = {
        device = "/dev/disk/by-label/NIXOS_BOOT";
        fsType = "vfat";
      };
    })

    (lib.mkIf (cfg.bootloader == "vendor") {
      # Un chargeur vendor ne lit pas extlinux : l'activer n'écrirait qu'un
      # fichier que personne ne lit, et donnerait l'illusion d'un `switch`
      # maître de l'amorçage.
      #
      # `mkForce` et non `mkDefault` : `nixbian` (nix/parts/nixos-module.nix)
      # pose `enable = true` en priorité normale — c'est le schéma par défaut
      # de ses images SD. Le schéma de l'unité doit trancher, pas cohabiter.
      boot.loader.generic-extlinux-compatible.enable = lib.mkForce false;
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
        # La console de cette famille est le ttyAML0 du pilote meson_serial,
        # pas le ttyS0 de l'8250 : le getty de ttyS0 échoue à chaque boot.
        consoleTty = lib.mkDefault "ttyAML0";
        watchdog = {
          enable = lib.mkDefault false;
          maxTimeout = lib.mkDefault null;
        };
      };
    })

    (lib.mkIf cfg.vpu.enable {
      hardware.nixbian.kernelModules.extraKeep = [ cfg.vpu.kernelModule ];
      boot.kernelModules = [ cfg.vpu.kernelModule ];
    })

    (lib.mkIf (cfg.vpu.enable && cfg.kernelPackage == null) {
      hardware.nixbian.extraPatches = cfg.vpu.patches;
      hardware.nixbian.extraConfig = cfg.vpu.config;
    })
  ];
}
