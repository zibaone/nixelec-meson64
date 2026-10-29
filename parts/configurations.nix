{ inputs, self, ... }:

let
  targetSystem = self.nixosConfigurations.magicsee-n5-bringup.config.system.build.toplevel;
in
{
  flake.nixosConfigurations.magicsee-n5-bringup = inputs.nixpkgs.lib.nixosSystem {
    system = "aarch64-linux";
    modules = [
      self.nixosModules.magicsee-n5
      ../examples/magicsee-n5-bringup.nix
    ];
  };

  flake.nixosConfigurations.magicsee-n5-sd = inputs.nixpkgs.lib.nixosSystem {
    system = "aarch64-linux";
    modules = [
      self.nixosModules.magicsee-n5
      self.nixosModules.sd-image
      ../examples/magicsee-n5-bringup.nix
    ];
  };

  flake.nixosConfigurations.magicsee-n5-installer = inputs.nixpkgs.lib.nixosSystem {
    system = "aarch64-linux";
    specialArgs = {
      n5TargetSystem = targetSystem;
      n5TargetKernel = self.nixosConfigurations.magicsee-n5-bringup.config.boot.kernelPackages.kernel;
      n5TargetDtb = self.nixosConfigurations.magicsee-n5-bringup.config.hardware.deviceTree.name;
      n5TargetBootParams = self.nixosConfigurations.magicsee-n5-bringup.config.boot.kernelParams;
    };
    modules = [
      self.nixosModules.magicsee-n5
      self.nixosModules.sd-image
      self.nixosModules.installer
      ../examples/magicsee-n5-installer.nix
    ];
  };

  flake.packages.aarch64-linux.magicsee-n5-sd-image =
    self.nixosConfigurations.magicsee-n5-sd.config.system.build.sdImage;

  # Image de qualification : mêmes fichiers de boot, plus l'outillage de mesure.
  flake.nixosConfigurations.magicsee-n5-decode = inputs.nixpkgs.lib.nixosSystem {
    system = "aarch64-linux";
    modules = [
      self.nixosModules.magicsee-n5
      self.nixosModules.decode-tools
      self.nixosModules.sd-image
      ../examples/magicsee-n5-bringup.nix
    ];
  };

  flake.packages.aarch64-linux.magicsee-n5-decode-image =
    self.nixosConfigurations.magicsee-n5-decode.config.system.build.sdImage;

  # Kiosque : mêmes fichiers de boot que le bring-up, plus Kodi en DRM direct.
  # Aucun compositeur — voir l'en-tête de modules/system/kodi.nix.
  flake.nixosConfigurations.magicsee-n5-kodi = inputs.nixpkgs.lib.nixosSystem {
    system = "aarch64-linux";
    modules = [
      self.nixosModules.magicsee-n5
      self.nixosModules.kodi
      self.nixosModules.sd-image
      ../examples/magicsee-n5-bringup.nix
    ];
  };

  flake.packages.aarch64-linux.magicsee-n5-kodi-image =
    self.nixosConfigurations.magicsee-n5-kodi.config.system.build.sdImage;

  flake.packages.aarch64-linux.magicsee-n5-installer-image =
    self.nixosConfigurations.magicsee-n5-installer.config.system.build.sdImage;
}
