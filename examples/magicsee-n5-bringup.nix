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

  services.openssh.enable = true;
  users.users.root.openssh.authorizedKeys.keys = [ ];
}
