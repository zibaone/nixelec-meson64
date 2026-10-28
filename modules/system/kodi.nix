# Kodi en kiosque, DRM direct (GBM), sans compositeur.
#
# Le paquet vient de `nix-v4l2-request` : il porte le backport DRM PRIME pour
# `v4l2-request`, remplace ffmpeg par le build patché et met
# `videoplayer.useprimedecoder` à true. Sans ce dernier point
# `CDVDVideoCodecDRMPRIME::Create()` renvoie nullptr et Kodi décode en CPU sans
# le dire — le reste du profil ne servirait à rien.
#
# Fenêtrage GBM et non Wayland : Kodi 21.3 demande le plein écran avant le
# mapping de sa surface (xbmc#20629, xbmc#27882), les compositeurs stricts
# ignorent la requête et Kodi ne dessine rien. En DRM direct il n'y a pas de
# négociation à rater.
{ config, lib, pkgs, ... }:

let
  cfg = config.nixelec.kodi;
in
{
  imports = [ ./vdec-firmware.nix ];

  options.nixelec.kodi = {
    enable = lib.mkEnableOption "Kodi en kiosque sur la sortie DRM";

    package = lib.mkOption {
      type = lib.types.package;
      description = ''
        Paquet Kodi à lancer. Le profil passe celui de `nix-v4l2-request`
        (`packages.<system>.kodi`, variante GBM).
      '';
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--debug" ];
      description = ''
        Arguments supplémentaires. Le paquet est déjà configuré pour GBM, il
        n'y a donc pas de `--windowing` à passer.
      '';
    };

    debug = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Garde la sortie de Kodi sur la console série en plus du journal. Utile
        pendant la qualification ; à couper une fois le rendu validé.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Sans les microcodes du VPU, Kodi choisit bien DRMPRIME mais chaque paquet
    # est rejeté (`Invalid data found when processing input`) : seul `dmesg`
    # nomme la cause. Le kiosque doit les embarquer, pas seulement l'image de
    # qualification.
    nixelec.vdecFirmware.enable = lib.mkDefault true;

    # Kodi a besoin d'EGL/GBM ; la famille meson64 le désactive par défaut
    # pour les images nues.
    hardware.graphics.enable = lib.mkForce true;

    # Kodi prend le DRM directement : personne ne doit lui disputer le VT.
    systemd.services."getty@tty1".enable = lib.mkForce false;

    # HDMI : mode fixe, l'EDID d'un téléviseur peut annoncer du 4K que GXL ne
    # compose pas.
    # Préférence de mode, PAS un forçage : pas de suffixe `D`. Avec `D`
    # (`DRM_FORCE_ON_DIGITAL`) le connecteur se déclare toujours `connected`,
    # le hotplug est désactivé et une panne de câble devient invisible —
    # seule la lecture de l'EDID prouve la détection. `mkForce` est nécessaire
    # parce que le module de carte force lui aussi la liste : à priorité égale
    # les listes se concatènent, sinon le paramètre est jeté en silence.
    boot.kernelParams = lib.mkForce [ "video=HDMI-A-1:1920x1080@60" ];

    users.groups.kodi = { };
    users.users.kodi = {
      isSystemUser = true;
      group = "kodi";
      home = "/var/lib/kodi";
      # DRM (video/render), télécommandes (input), HDMI (audio).
      extraGroups = [
        "video"
        "render"
        "input"
        "audio"
      ];
    };

    systemd.services.kodi = {
      description = "Kodi (kiosque DRM/GBM)";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "systemd-udev-settle.service"
      ];
      environment = {
        HOME = "/var/lib/kodi";
        KODI_DATA = "/var/lib/kodi/.kodi";
      };
      serviceConfig = {
        Type = "simple";
        User = "kodi";
        Group = "kodi";
        SupplementaryGroups = [
          "video"
          "render"
          "input"
          "audio"
        ];
        ExecStart = "${cfg.package}/bin/kodi ${lib.concatStringsSep " " cfg.extraArgs}";
        WorkingDirectory = "/var/lib/kodi";
        StateDirectory = "kodi";
        # Un kiosque qui meurt doit revenir : c'est le seul programme visible.
        Restart = "always";
        RestartSec = 3;
        StandardOutput = if cfg.debug then "journal+console" else "journal";
        StandardError = if cfg.debug then "journal+console" else "journal";
      };
    };

    environment.systemPackages = [ cfg.package ];
  };
}
