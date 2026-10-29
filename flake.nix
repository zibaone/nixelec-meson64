{
  description = "nixelec-meson64 — couche NixOS réutilisable pour Amlogic meson64 (GX/G12/SM1)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    flake-parts.url = "github:hercules-ci/flake-parts";

    nixbian = {
      # Branche de travail : elle porte la série meson-amvdec (patchs
      # amlogic-0118..0128). Le lock fige le rev, mais pointer la branche rend
      # la provenance explicite ; un `nix flake update` sur ce flake la suit.
      url = "github:zibaone/nixbian/feat/meson64-vdec-7.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    v4l2request = {
      url = "github:zibaone/nix-v4l2-request";
      inputs.nixpkgs.follows = "nixpkgs";
    };

  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      imports = [
        ./parts/modules.nix
        ./parts/configurations.nix
        ./parts/packages.nix
        ./parts/checks.nix
      ];
    };
}
