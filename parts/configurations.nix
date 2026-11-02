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
      # Étiquette que l'installateur doit poser sur la racine de la cible
      # (`mkfs.ext4 -L`) : elle doit être celle que la cible attend, sinon
      # stage-1 ne trouve pas sa racine au premier démarrage.
      n5TargetRootLabel = self.nixosConfigurations.magicsee-n5-bringup.config.nixelec.rootLabel;
      # BL33 mainline (U-Boot p212) construit dans le jeu croisé x86_64 →
      # aarch64 : la construction reste native, donc en secondes. L'installateur
      # l'assemble avec les BL2/BL30/BL31 lus sur la carte cible.
      n5UbootBl33 = import ../pkgs/uboot-p212-bl33.nix {
        pkgsX86 = inputs.nixpkgs.legacyPackages.x86_64-linux;
      };
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

  flake.packages.aarch64-linux.magicsee-n5-installer-image =
    self.nixosConfigurations.magicsee-n5-installer.config.system.build.sdImage;
}
