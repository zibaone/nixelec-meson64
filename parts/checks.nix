{ self, inputs, ... }:

{
  perSystem =
    {
      lib,
      pkgs,
      system,
      ...
    }:
    lib.optionalAttrs (system == "x86_64-linux") {
      checks = {
        meson64-family-kernel =
          let
            kernels = inputs.nixbian.legacyPackages.${system}.meson64.kernels or { };
            kernel = kernels.meson64-edge or null;
          in
          if kernel == null then
            throw "nixelec: nixbian does not expose legacyPackages.${system}.meson64.kernels.meson64-edge."
          else
            pkgs.runCommand "check-meson64-family-kernel"
              {
                drv = builtins.unsafeDiscardStringContext kernel.drvPath;
              }
              ''
                test -n "$drv"
                touch $out
              '';

        formatting =
          pkgs.runCommand "check-nixfmt"
            {
              nativeBuildInputs = [ pkgs.nixfmt ];
            }
            ''
              find ${self} -name '*.nix' -exec nixfmt --check {} +
              touch $out
            '';

        # Le shim `nixelec.wifi` doit alimenter le client commun : sans cette
        # éval, une régression du mapping (enable/networksFile) ne se verrait
        # qu'au boot de la N5.
        eval-wifi-ath10k =
          let
            cfg = inputs.nixpkgs.lib.nixosSystem {
              system = "x86_64-linux";
              modules = [
                self.nixosModules.wifi-ath10k
                {
                  nixelec.wifi = {
                    enable = true;
                    networksFile = "/run/wpa_supplicant.conf";
                  };
                }
              ];
            };
          in
          builtins.seq cfg.config.systemd.services.wpa-supplicant-wlan0.name (
            pkgs.runCommand "eval-wifi-ath10k" { } "touch $out"
          );
      };
    };
}
