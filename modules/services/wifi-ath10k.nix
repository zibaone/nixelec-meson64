# WiFi QCA9377 (ath10k_sdio) — couche carte meson64.
#
# Le client WPA (options, rendu de /run/wpa_supplicant.conf, extinction de la
# veille firmware) vit dans nixelec-common. Ce module ne garde que ce qui est
# propre à la carte : le module noyau, le firmware QCA9377 et le shim
# `nixelec.wifi` qui conserve les noms historiques pour les profils et
# `services/havenos/wifi-networks.nix`.
#
# Pourquoi le module noyau est explicite : l'arbre de modules est élagué par
# nixbian ; `ath10k_sdio` n'a pas d'alias `of:` dans le DTB p212, donc sans
# entrée dans `boot.kernelModules` (qui alimente aussi l'allowlist de
# l'élagage) le module disparaît et `modprobe` répond « Module not found ».
#
# iwd n'est pas utilisé : le client commun le désactive (`mkForce false`),
# parce qu'il recrée l'interface au démarrage et que rien ne prouve que la
# pile SDIO de cette carte survive à un `DEL_INTERFACE`.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.nixelec.wifi;
  client = config.nixelec.wifiClient;

  # Les deux surfaces sont acceptées pendant la migration : `cfg.enable` pour
  # les profils écrits avant nixelec-common, `client.enable` pour les nouveaux.
  driverEnable = cfg.enable || client.enable;

  # Même paquet que modules/system/minimal.nix, qui le pose en `mkForce` pour
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

  config = {
    # Shim : les anciens noms restent des données de carte ; le client commun
    # les consomme. `mkDefault` laisse la nouvelle surface gagner si un profil
    # l'écrit explicitement.
    nixelec.wifiClient = {
      enable = lib.mkDefault cfg.enable;
      interface = lib.mkDefault cfg.interface;
      ssid = lib.mkDefault cfg.ssid;
      pskFile = lib.mkDefault cfg.pskFile;
      networksFile = lib.mkDefault cfg.networksFile;
      powerSaveOff = lib.mkDefault cfg.powerSaveOff;
    };

    boot.kernelModules = lib.mkIf driverEnable [ "ath10k_sdio" ];

    # `hardware.firmware` est écrasé en mkForce par minimal.nix sur les images
    # nues ; là-bas c'est minimal.nix qui fournit déjà ces fichiers. Sur un hôte
    # de flotte, c'est cette définition qui s'applique.
    hardware.firmware = lib.mkIf driverEnable [ qca9377Firmware ];
  };
}
