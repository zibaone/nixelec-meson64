{
  config,
  lib,
  pkgs,
  modulesPath,
  n5TargetSystem,
  n5TargetRootLabel,
  n5TargetBootloader,
  n5TargetDtb,
  n5UbootBl33,
  ...
}:

let
  # gxlimg pour aarch64 : l'installateur assemble le FIP SUR LA CARTE, parce
  # que ses composants ne sont pas interchangeables d'une unité à l'autre.
  gxlimg = pkgs.callPackage ../../pkgs/gxlimg.nix { };

  # Écriture du BL33, **sans toucher aux partitions** : ce script peut être
  # lancé seul sur une carte déjà installée (remplacement du chargeur sans
  # réinstallation), ou appelé par `n5-install` en dernière étape.
  #
  # Arguments : $1 = disque (défaut /dev/mmcblk1), $2 = sauvegarde,
  # $3 = horodatage (pour réutiliser la sauvegarde d'un appelant).
  ubootScript = import ../../pkgs/n5-uboot-install.nix {
    inherit pkgs gxlimg;
    bl33 = n5UbootBl33;
  };

  # Le plan et le provider sont concaténés au moteur : le script rendu reste un
  # seul fichier, autonome sur la carte, mais il est écrit en trois morceaux
  # (plan baké, provider de famille, mécanique) au lieu d'un monolithe.
  #
  # Contrat : `docs/specs/04-contrat-provisioning-plateforme.md`. Le schéma est
  # baké ici ET dans le plan ; le moteur refuse un plan qui le contredit, et un
  # plan reçu ne peut jamais changer la décision d'écrire le chargeur.
  provider = builtins.readFile ./provisioning/platforms/meson64.sh;
  engine = builtins.readFile ./provisioning/engine.sh;

  installScript = pkgs.writeShellScript "n5-install" ''
    set -euo pipefail

    # ---- plan baké (la cible porte le schéma et l'étiquette) ----------------
    plan_family="meson64"
    plan_board="${config.hardware.nixbian.board}"
    plan_scheme="${n5TargetBootloader}"
    plan_root_label="${n5TargetRootLabel}"
    plan_system="${n5TargetSystem}"
    plan_dtb="${n5TargetDtb}"
    plan_layout="keep"
    plan_boot_mib="488"
    baked_scheme="${n5TargetBootloader}"
    uboot_script="${ubootScript}"

    # ---- plan reçu de l'assemblage (HavenOS), sinon plan baké --------------
    # Le plan vit désormais dans la configuration de l'unité
    # (`havenos.installPlan`, HavenOS `modules/hardware/families/meson64/
    # install-plan.nix`) : l'étage 2 n'a plus à être « meson64 ». Les variables
    # `plan_*` ci-dessus restent le repli quand l'image est construite sans
    # plan, et le moteur refuse de toute façon un plan dont le schéma diffère
    # du schéma baké.
    if [ -z "''${N5_PLAN:-}" ] && [ -f /etc/n5/plan.json ]; then
      N5_PLAN=/etc/n5/plan.json
      export N5_PLAN
    fi

    # ---- provider de plateforme, puis moteur -------------------------------
    ${provider}
    ${engine}
  '';
in
{
  image.fileName = lib.mkForce "nixelec-meson64-${config.hardware.nixbian.board}-installer.img";

  environment.systemPackages = with pkgs; [
    nixos-install-tools
    dosfstools
    e2fsprogs
    util-linux
    diffutils
    zstd
    gxlimg
    # `mkimage` pour la charge utile vendor, générée sur la carte après
    # `nixos-install` (la branche mainline n'en a pas besoin, mais l'outil est
    # dans la fermeture de l'image, pas dans un chemin conditionnel).
    ubootTools
    # Lecture d'un plan reçu (`--plan`) ; le plan baké n'en a pas besoin.
    jq
  ];

  system.extraDependencies = [
    n5TargetSystem
    n5UbootBl33
  ];

  environment.etc."n5/install.sh".source = installScript;
  # Remplacement du seul BL33, sans reformater : utilisable sur une carte déjà
  # installée (essai d'un chargeur, retour arrière).
  environment.etc."n5/uboot-install.sh".source = "${ubootScript}/bin/n5-uboot";

  services.getty.autologinUser = lib.mkForce "root";
  systemd.services."serial-getty@ttyAML0".enable = true;
}
