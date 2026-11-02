{
  lib,
  stdenv,
  fetchFromGitHub,
  openssl,
  lz4,
}:

# gxlimg — outillage Amlogic : extraction et assemblage du FIP (BL2/BL30/BL31/
# BL33) et chiffrement bl3x. Absent de nixpkgs, d'où ce paquet.
#
# Il est embarqué dans l'installateur (aarch64) : c'est lui qui permet de
# fabriquer le FIP candidat SUR LA CARTE, à partir des composants réellement
# installés sur l'unité. Le FIP n'est pas reproductible d'une carte à l'autre
# (la ROM vérifie BL1→BL2 et le BL2 porte le DDR init de la carte), donc un
# binaire préparé d'avance ne conviendrait qu'à l'unité qui l'a produit.
stdenv.mkDerivation (finalAttrs: {
  pname = "gxlimg";
  version = "unstable-2026-10-22";

  src = fetchFromGitHub {
    owner = "repk";
    repo = "gxlimg";
    rev = "6d346b43444e139e7311c88b7d35d994c64a1e05";
    hash = "sha256-wDEl6G7zIfvwovbtqUYpd27uxKekAyDwUHMsF+qXcjI=";
  };

  # `LDFLAGS ?= -lssl -lcrypto -llz4` : les chemins viennent de NIX_LDFLAGS
  # (buildInputs), il n'y a donc pas de rpath à poser à la main.
  buildInputs = [
    openssl
    lz4
  ];

  makeFlags = [ "CC=cc" ];

  # Le Makefile n'a pas de cible `install` : il produit `gxlimg` à la racine
  # de l'arbre et se lance depuis là.
  installPhase = ''
    runHook preInstall
    install -Dm755 gxlimg $out/bin/gxlimg
    runHook postInstall
  '';

  doCheck = false;

  meta = {
    description = "Amlogic gxl image tool: FIP assembly and bl3x encryption";
    homepage = "https://github.com/repk/gxlimg";
    license = lib.licenses.gpl2Plus;
    mainProgram = "gxlimg";
    platforms = lib.platforms.linux;
  };
})
