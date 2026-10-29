{ pkgs, lib, config, ... }:

let
  qca9377 = pkgs.runCommand "qca9377-firmware" { nativeBuildInputs = [ pkgs.zstd ]; } ''
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
  options.nixelec.extraFirmware = lib.mkOption {
    type = lib.types.listOf lib.types.package;
    default = [ ];
    description = ''
      Paquets firmware ajoutés en plus du strict nécessaire (WiFi QCA9377).

      `minimal.nix` force `hardware.firmware` pour que l'image de bring-up
      reste nue ; c'est le point d'extension prévu pour un profil qui a besoin
      d'un microcode supplémentaire (par exemple le VPU Amlogic), sans avoir à
      rejouer un `mkForce` concurrent.
    '';
  };

  config = {
    documentation = {
      enable = lib.mkDefault false;
      nixos.enable = lib.mkDefault false;
      man.enable = lib.mkDefault false;
      info.enable = lib.mkDefault false;
      doc.enable = lib.mkDefault false;
    };

    nix.registry = lib.mkForce { };
    nix.nixPath = lib.mkForce [ ];

    hardware.enableRedistributableFirmware = lib.mkForce false;
    hardware.nixbian.compressFirmware = lib.mkForce false;
    # Le noyau nixbian a `# CONFIG_FW_LOADER_COMPRESS is not set` : tout
    # firmware livré en .zst/.xz est ignoré par request_firmware(). La valeur
    # par défaut de nixpkgs est justement "zstd", donc on la neutralise, sinon
    # ni le WiFi (ath10k) ni le VPU (meson/vdec) ne chargent leur microcode.
    hardware.firmwareCompression = lib.mkForce "none";
    hardware.firmware = lib.mkForce ([ qca9377 ] ++ config.nixelec.extraFirmware);

    boot.supportedFilesystems = lib.mkForce [
      "vfat"
      "ext4"
    ];
    services.xserver.enable = lib.mkForce false;
    fonts.fontconfig.cache32Bit = false;
    i18n.defaultLocale = lib.mkForce "C.UTF-8";

    services.journald.extraConfig = lib.mkDefault ''
      Storage=volatile
      RuntimeMaxUse=32M
    '';

    environment.defaultPackages = lib.mkForce (
      with pkgs;
      [
        bashInteractive
        coreutils
        iproute2
        kmod
        less
        nano
        procps
        util-linux
      ]
    );
  };
}
