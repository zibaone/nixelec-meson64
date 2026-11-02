{ pkgsX86 }:

# BL33 (U-Boot mainline) pour la Magicsee N5 — SoC Amlogic S905L, carte p212.
#
# Construit dans le jeu de paquets CROISÉ depuis x86_64 : `buildUBoot` pose
# `CROSS_COMPILE=${stdenv.cc.targetPrefix}`, donc le compilateur aarch64 tourne
# nativement sur l'hôte et la construction prend des secondes. Évalué dans le
# jeu aarch64 du flake, il tournerait sous binfmt/qemu.
#
# Commit épinglé = le binaire validé sur la carte (bannière
# « U-Boot 2027.01-rc1-g3973f3c4d24d p212 »). Changer ce commit, c'est changer
# le BL33 : il faut revalider le démarrage avant de le livrer.
#
# Ce binaire est une DONNÉE pour l'installateur (aarch64) : il est chiffré par
# `gxlimg -t bl3x -c` puis assemblé dans le FIP de l'unité cible. Le reste du
# FIP (BL2/BL30/BL31) vient du dump de la carte, jamais de ce paquet.
pkgsX86.pkgsCross.aarch64-multiplatform.buildUBoot {
  defconfig = "p212_defconfig";
  version = "2027.01-rc1-g3973f3c4d24d";

  src = pkgsX86.fetchgit {
    url = "https://source.denx.de/u-boot/u-boot.git";
    rev = "3973f3c4d24df75ca90d7c0a9f03e5e5c9b48f32";
    hash = "sha256-54SgEpZSO9/F4W1pygvkUCwXbEIjDOil61x1IpFFcNA=";
  };

  filesToInstall = [ "u-boot.bin" ];
}
