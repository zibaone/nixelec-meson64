# WiFi QCA9377 (ath10k_sdio) — couche carte meson64.
#
# Le pilote est dans le noyau, mais l'arbre de modules est élagué par nixbian :
# `ath10k_sdio` n'a pas d'alias `of:` dans le DTB p212, donc sans entrée dans
# `boot.kernelModules` (qui alimente aussi l'allowlist de l'élagage) le module
# disparaît et `modprobe` répond « Module not found ».
#
# Le service `wpa_supplicant` vivait dans un module de laboratoire non
# versionné ; il est réécrit ici, avec la même surface d'options que la couche
# sunxi (`nixelec.wifi.*`) : un profil de flotte paramètre SSID et PSK sans
# savoir quelle puce porte la carte.
#
# iwd n'est pas utilisé : il recrée l'interface au démarrage, et rien ne prouve
# que la pile SDIO de cette carte survive à un `DEL_INTERFACE`.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.nixelec.wifi;

  # Deux sources possibles pour /run/wpa_supplicant.conf :
  #  - `networksFile` : la donnée (secret M2) rendue au boot, un fichier
  #    wpa_supplicant complet — plus aucun SSID ni PSK dans la configuration ;
  #  - `ssid` + `pskFile` : le couple historique, gardé pour les images de
  #    secours et comme repli pendant une migration.
  # Les deux unités doivent exister dès qu'une source est déclarée, sinon une
  # carte en config-as-data n'aurait ni wpa-psk ni wpa_supplicant.
  hasSsid = cfg.ssid != null && cfg.pskFile != null;
  hasNetworks = cfg.networksFile != null;
  hasSource = hasSsid || hasNetworks;

  # Même contenu que modules/system/minimal.nix, qui le pose en `mkForce` pour
  # les images nues (bring-up, decode). Ce module est le seul chemin sur un
  # hôte de flotte, qui n'importe pas minimal.nix : il doit fournir le firmware
  # lui-même.
  #
  # `compressFirmware = false` : le noyau nixbian a
  # `# CONFIG_FW_LOADER_COMPRESS is not set`, donc tout fichier livré en .zst
  # serait ignoré par request_firmware(). Les fichiers de linux-firmware sont
  # décompressés ici et le paquet échappe à la compression de NixOS.
  qca9377Firmware =
    pkgs.runCommand "qca9377-firmware"
      {
        nativeBuildInputs = [ pkgs.zstd ];
        compressFirmware = false;
      }
      ''
        mkdir -p $out/lib/firmware/ath10k/QCA9377/hw1.0 $out/lib/firmware/qca
        cp -L ${pkgs.linux-firmware}/lib/firmware/ath10k/QCA9377/hw1.0/* $out/lib/firmware/ath10k/QCA9377/hw1.0/
        cp -rL ${pkgs.linux-firmware}/lib/firmware/qca/* $out/lib/firmware/qca/
        for f in regulatory.db regulatory.db.p7s; do
          cp -L ${pkgs.linux-firmware}/lib/firmware/$f $out/lib/firmware/ 2>/dev/null || true
        done
        find $out/lib/firmware -name '*.zst' -exec zstd -d --rm {} \;
        find $out/lib/firmware -xtype l -delete
      '';
in
{
  options.nixelec.wifi = {
    enable = lib.mkEnableOption "QCA9377 (ath10k_sdio) WiFi";

    interface = lib.mkOption {
      type = lib.types.str;
      default = "wlan0";
      description = "WiFi interface created by the driver.";
    };

    ssid = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "SSID to associate with. If null, wpa_supplicant is not started.";
    };

    pskFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Path to a file containing the PSK, read at boot (for example
        /run/agenix/wifi-psk). Never put the PSK in the Nix store.
      '';
    };

    networksFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = ''
        Path to a complete wpa_supplicant configuration (one or more
        `network={…}` blocks), read at boot. When the file exists it takes
        precedence over `ssid`/`pskFile`: the card then carries **no** WiFi
        identity in its Nix configuration, only the path of a data file
        rendered by the provisioning layer (config-as-data). The file must be
        under `/run`: the clear-text never touches the disk.
      '';
    };

    powerSaveOff = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Disable firmware power saving after association.";
    };
  };

  config = lib.mkIf cfg.enable {
    boot.kernelModules = [ "ath10k_sdio" ];

    # `hardware.firmware` est écrasé en mkForce par minimal.nix sur les images
    # nues ; là-bas c'est minimal.nix qui fournit déjà ces fichiers. Sur un hôte
    # de flotte, c'est cette définition qui s'applique.
    hardware.firmware = [ qca9377Firmware ];

    networking.wireless.iwd.enable = lib.mkForce false;

    systemd.services.wpa-psk = lib.mkIf hasSource {
      description = "Render /run/wpa_supplicant.conf from a secret file";
      wantedBy = [ "wpa-supplicant-${cfg.interface}.service" ];
      before = [ "wpa-supplicant-${cfg.interface}.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        umask 077
        conf=/run/wpa_supplicant.conf
      ''
      + lib.optionalString hasNetworks ''
        # La donnée prime : fichier wpa_supplicant complet, rendu au boot par
        # le provisioning (`havenos-secrets`). Rien à parser, rien à cuire.
        if [ -r ${lib.escapeShellArg cfg.networksFile} ]; then
          cat ${lib.escapeShellArg cfg.networksFile} > "$conf"
          exit 0
        fi
      ''
      + lib.optionalString hasSsid ''
        # Repli : couple ssid + PSK (image de secours, migration en cours).
        {
          printf 'network={\n'
          printf '\tssid="%s"\n' ${lib.escapeShellArg cfg.ssid}
          printf '\tpsk="%s"\n' "$(cat ${lib.escapeShellArg cfg.pskFile})"
          printf '}\n'
        } > "$conf"
        exit 0
      ''
      + ''
        # Aucune source exploitable : échec visible plutôt qu'un fichier vide
        # que wpa_supplicant refuserait en boucle (mesuré sur la Zero 3 :
        # 49 redémarrages, boucle qui masquait la vraie panne).
        echo "wpa-psk: aucune source de réseaux lisible (${
          if hasNetworks then cfg.networksFile else "networksFile"
        } / ssid+pskFile)" >&2
        exit 1
      '';
    };

    systemd.services."wpa-supplicant-${cfg.interface}" = lib.mkIf hasSource {
      description = "wpa_supplicant (${cfg.interface})";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network-pre.target"
        "wpa-psk.service"
      ];
      wants = [ "wpa-psk.service" ];
      before = [ "network.target" ];
      # Sans conf rendue (secret non provisionné), wpa_supplicant sort en 255
      # et systemd le relance sans fin : on saute l'unité (état « skipped »,
      # pas « failed ») et `havenos provision` la relance après le PSK.
      unitConfig.ConditionPathExists = "/run/wpa_supplicant.conf";
      startLimitIntervalSec = 300;
      startLimitBurst = 5;
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.wpa_supplicant}/sbin/wpa_supplicant -c /run/wpa_supplicant.conf -i ${cfg.interface}";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    systemd.services.wlan-ps-off = lib.mkIf cfg.powerSaveOff {
      description = "Disable WiFi firmware power saving (QCA9377)";
      wantedBy = [ "multi-user.target" ];
      after = [ "wpa-supplicant-${cfg.interface}.service" ];
      serviceConfig = {
        # Type=simple: the script waits for the IPv4 address and then toggles
        # the firmware; a oneshot would make multi-user.target wait for the
        # whole loop.
        Type = "simple";
      };
      script = ''
        # cfg80211 already reports power_save=off by default: setting only
        # `off` is a no-op and never reaches the firmware. Toggle on then off
        # to force the call.
        #
        # Wait for association (the IPv4 address), not just for the netdevice:
        # the driver resets the power-save setting when wpa_supplicant
        # associates.
        for _ in $(seq 1 120); do
          if ${pkgs.iproute2}/bin/ip -4 addr show dev ${cfg.interface} 2>/dev/null | grep -q 'inet '; then
            sleep 1
            ${pkgs.iw}/bin/iw dev ${cfg.interface} set power_save on 2>/dev/null
            sleep 1
            ${pkgs.iw}/bin/iw dev ${cfg.interface} set power_save off 2>/dev/null && exit 0
          fi
          sleep 1
        done
        echo "${cfg.interface}: not associated after 120s; power save left unchanged" >&2
        exit 0
      '';
    };
  };
}
