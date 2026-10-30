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
      # Trois fichiers bruts (`Image`, `initrd`, DTB) et `booti`, plutôt qu'un
      # `uImage.multi` : mesuré sur la carte le 30/10, le multi-image était le
      # seul fichier dont le contenu sur la eMMC divergeait, alors que `Image`
      # (38 Mo) et `initrd` (25 Mo) se lisaient correctement. `booti` accepte un
      # initrd brut, là où ce vieux `bootm` exige un ramdisk uImage
      # (« Wrong Ramdisk Image Format »).
      script = pkgs.writeText "n5-autoscript.txt" ''
        setenv bootargs "${bootArgs}"
        setenv kernel_addr 0x1080000
        setenv initrd_addr 0x13000000
        setenv fdt_addr 0x1000000
        setenv mmcdev 0
        if fatload mmc 0:1 ''${kernel_addr} Image; then
          setenv mmcdev 0
        else
          setenv mmcdev 1
          fatload mmc 1:1 ''${kernel_addr} Image
        fi
        fatload mmc ''${mmcdev}:1 ''${initrd_addr} initrd
        fatload mmc ''${mmcdev}:1 ''${fdt_addr} ${dtbBase}
        echo "Booting NixOS from mmc ''${mmcdev}:1"
        booti ''${kernel_addr} ''${initrd_addr}:@INITRD_SIZE@ ''${fdt_addr}
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
      # `booti` veut la taille de l'initrd en clair : on la mesure à la
      # construction plutôt qu'à l'exécution, le script restant statique.
      sed "s/@INITRD_SIZE@/$(stat -L -c %s ${initrd})/" ${script} > $out/s905_autoscript.txt
      cp ${uEnv} $out/uEnv.ini
      mkimage -A arm64 -O linux -T script -C none -n "N5 boot" -d $out/s905_autoscript.txt $out/s905_autoscript
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
