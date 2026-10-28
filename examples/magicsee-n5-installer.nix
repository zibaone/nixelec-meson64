{
  nixelec.vpu.enable = true;

  networking.hostName = "n5-installer";
  system.stateVersion = "26.05";

  fileSystems."/" = {
    device = "/dev/disk/by-label/N5_INSTALL";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/N5_BOOT";
    fsType = "vfat";
  };

  sdImage.rootVolumeLabel = "N5_INSTALL";
  sdImage.firmwarePartitionName = "N5_BOOT";

}
