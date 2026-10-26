{ inputs, self, ... }:

{
  flake.nixosConfigurations.magicsee-n5-bringup = inputs.nixpkgs.lib.nixosSystem {
    system = "aarch64-linux";
    modules = [
      self.nixosModules.magicsee-n5
      ../examples/magicsee-n5-bringup.nix
    ];
  };
}
