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
        # Modèle B : le noyau N5 est celui de la couche (crossKernel, patches
        # VDEC locaux), pas legacyPackages.meson64.kernels de nixbian. Cette
        # éval force le toplevel donc le noyau et ses extraPatches.
        eval-magicsee-n5 = pkgs.runCommand "check-eval-magicsee-n5" { } ''
          echo ${builtins.unsafeDiscardStringContext self.nixosConfigurations.magicsee-n5-sd.config.system.build.toplevel.drvPath} > $out
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
