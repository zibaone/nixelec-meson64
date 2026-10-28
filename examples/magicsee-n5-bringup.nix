{
  nixelec.vpu.enable = true;

  networking.hostName = "magicsee-n5";
  system.stateVersion = "26.05";

  fileSystems."/" = {
    device = "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/NIXOS_BOOT";
    fsType = "vfat";
  };

  system.disableInstallerTools = true;
  nix.enable = false;
  systemd.services.register-nix-paths.enable = false;

  services.getty.autologinUser = "root";
  systemd.services."serial-getty@ttyAML0".enable = true;

}
