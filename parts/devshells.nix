{
  perSystem =
    { pkgs, ... }:
    let
      # Chaîne croisée aarch64 : le S905X est un Cortex-A53, U-Boot se compile
      # avec le préfixe `aarch64-unknown-linux-gnu-` (ce que fournit `stdenv.cc`
      # du jeu croisé, contrairement à `buildPackages` qui reste l'hôte).
      cross = pkgs.pkgsCross.aarch64-multiplatform;
      aml = pkgs.callPackage ../pkgs/pyamlboot.nix { };
    in
    {
      devShells.uboot = pkgs.mkShell {
        name = "nixelec-meson64-uboot";

        packages = with pkgs; [
          # construction d'U-Boot
          gnumake
          bison
          flex
          bc
          swig
          python3
          perl
          openssl
          gnutls
          libuuid
          dtc
          ubootTools # mkimage, dumpimage, mkenvimage
          cross.stdenv.cc
          cross.binutils
          cpio
          gzip
          lz4
          zstd
          git

          # récupération MaskROM par le câble USB A-A
          libusb1
          usbutils
          python3Packages.pyusb
          aml.amlboot # charge un U-Boot en RAM, n'écrit rien
          aml.amlbulk
          aml.amlsocid

          # console série et inspection
          picocom
          minicom
          xxd
          file
        ];

        shellHook = ''
          export ARCH=arm64
          export CROSS_COMPILE=aarch64-unknown-linux-gnu-
          echo "nixelec-meson64 — atelier U-Boot (Amlogic gxl, S905X / p212)"
          echo "  ARCH=$ARCH  CROSS_COMPILE=$CROSS_COMPILE"
          echo "  amont    : git clone https://source.denx.de/u-boot/u-boot.git"
          echo "  config   : make p212_defconfig"
          echo "  build    : make -j\$(nproc)"
          echo "  SD       : u-boot.bin.sd.bin en tête de carte (premier MiB)"
          echo "  MaskROM  : amlboot p212 --image build-uboot/fip/u-boot.bin.usb.tpl"
          echo "             (câble USB A-A ; lsusb doit montrer 1b8e:c003)"
          echo "  FIP      : ./scripts/uboot-p212-fip.sh (build-fip.sh lepotato)"
        '';
      };
    };
}
