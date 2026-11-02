{
  config,
  ...
}:

{
  nixelec.vpu.enable = true;

  networking.hostName = "magicsee-n5";
  system.stateVersion = "26.05";

  fileSystems."/" = {
    device = "/dev/disk/by-label/${config.nixelec.rootLabel}";
    fsType = "ext4";
  };

  # `/boot` n'est **pas** déclaré ici : il appartient au schéma d'amorçage.
  # `nixelec.bootloader = "mainline"` monte `NIXOS_BOOT` dessus (c'est ce qui
  # fait suivre les générations par `switch`) ; en `vendor`, la FAT n'est pas
  # montée — la charge utile épinglée y est posée par l'installateur et relue
  # par le chargeur vendor, pas par le système.

  system.disableInstallerTools = true;
  nix.enable = false;
  systemd.services.register-nix-paths.enable = false;

  services.getty.autologinUser = "root";
  systemd.services."serial-getty@ttyAML0".enable = true;

}
