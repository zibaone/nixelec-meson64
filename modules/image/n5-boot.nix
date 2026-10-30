{ pkgs, lib }:

{
  mkBootFiles =
    {
      kernel,
      initrd,
      dtbName,
      rootLabel,
      bootParams,
      toplevel,
    }:
    let
      dtbBase = builtins.baseNameOf dtbName;
      # `init=` is mandatory: stage-1's initrd-find-nixos-closure reads it from
      # /proc/cmdline and exits 1 without it ("No init= parameter on the kernel
      # command line"). GRUB/extlinux normally inject it; our vendor-U-Boot
      # autoscript sets bootargs by hand, so we must add it explicitly.
      bootArgs = lib.concatStringsSep " " (
        bootParams
        ++ [
          "root=LABEL=${rootLabel}"
          "rootwait"
          "rw"
          "init=${toplevel}/init"
        ]
      );
      # Trois fichiers plutôt qu'un `uImage.multi` de 63 Mo : mesuré sur la
      # carte le 30/10, le multi-image était le seul fichier dont la lecture
      # depuis la eMMC divergeait (CRC faux au `bootm`), alors que `Image`
      # (38 Mo) et `initrd` (25 Mo) se lisaient correctement. Un fichier de
      # moins, c'est une panne de moins, et `bootm` à trois arguments vérifie
      # le noyau sans dépendre du conteneur multi.
      script = pkgs.writeText "n5-autoscript.txt" ''
        setenv bootargs "${bootArgs}"
        setenv kernel_addr 0x1080000
        setenv initrd_addr 0x13000000
        setenv fdt_addr 0x1000000
        setenv mmcdev 0
        if fatload mmc 0:1 ''${kernel_addr} uImage; then
          setenv mmcdev 0
        else
          setenv mmcdev 1
          fatload mmc 1:1 ''${kernel_addr} uImage
        fi
        fatload mmc ''${mmcdev}:1 ''${initrd_addr} initrd
        fatload mmc ''${mmcdev}:1 ''${fdt_addr} ${dtbBase}
        echo "Booting NixOS from mmc ''${mmcdev}:1"
        bootm ''${kernel_addr} ''${initrd_addr} ''${fdt_addr}
      '';
      uEnv = pkgs.writeText "uEnv.ini" ''
        dtb_name=/${dtbBase}
        bootargs=${bootArgs}
      '';
    in
    pkgs.runCommand "n5-boot-files" { nativeBuildInputs = [ pkgs.ubootTools ]; } ''
      mkdir -p $out
      cp ${kernel}/Image $out/Image
      cp ${initrd} $out/initrd
      cp ${kernel}/dtbs/${dtbName} $out/${dtbBase}
      cp ${script} $out/s905_autoscript.txt
      cp ${uEnv} $out/uEnv.ini
      mkimage -A arm64 -O linux -T script -C none -n "N5 boot" -d ${script} $out/s905_autoscript
      cp $out/s905_autoscript $out/boot.scr
      # Le U-Boot vendor charge `emmc_autoscript` sur mmc 1 quand il démarre
      # depuis la eMMC (`start_emmc_autoscript`), et `s905_autoscript` sur mmc 0
      # pour la SD. C'est le même script : il tente déjà mmc 0:1 puis retombe
      # sur mmc 1:1, donc une simple copie suffit.
      cp $out/s905_autoscript $out/emmc_autoscript
      mkimage -A arm64 -O linux -T kernel -C none -a 0x1080000 -e 0x1080000 -n NixOS -d ${kernel}/Image $out/uImage
      mkimage -A arm64 -O linux -T multi -C none -a 0x1080000 -e 0x1080000 -n "NixOS multi" -d ${kernel}/Image:${initrd} $out/uImage.multi
    '';
}
