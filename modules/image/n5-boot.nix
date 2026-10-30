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
      # Recette des cartes Amlogic à U-Boot vendor (cf. les autoscripts
      # « box » d'Armbian/LibreELEC, seuls connus pour démarrer sur ce
      # chargeur) : noyau à 0x02000000 (2 Mio d'alignement), initrd en uImage
      # à 0x13000000, DTB à 0x04000000, `fdt addr` posé, puis `booti` SANS
      # suffixe de taille. Le `booti` du vendor ne suit pas la syntaxe
      # `<initrd>:<taille>` d'U-Boot amont ; `bootm` refuse un initrd brut
      # (« Wrong Ramdisk Image Format »).
      script = pkgs.writeText "n5-autoscript.txt" ''
        setenv bootargs "${bootArgs}"
        setenv kernel_addr 0x2000000
        setenv initrd_addr 0x13000000
        setenv fdt_addr 0x4000000
        setenv mmcdev 0
        if fatload mmc 0:1 ''${kernel_addr} Image; then
          setenv mmcdev 0
        else
          setenv mmcdev 1
          fatload mmc 1:1 ''${kernel_addr} Image
        fi
        fatload mmc ''${mmcdev}:1 ''${initrd_addr} uInitrd
        fatload mmc ''${mmcdev}:1 ''${fdt_addr} ${dtbBase}
        fdt addr ''${fdt_addr}
        echo "Booting NixOS from mmc ''${mmcdev}:1"
        booti ''${kernel_addr} ''${initrd_addr} ''${fdt_addr}
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
      cp ${script} $out/s905_autoscript.txt
      cp ${uEnv} $out/uEnv.ini
      mkimage -A arm64 -O linux -T script -C none -n "N5 boot" -d $out/s905_autoscript.txt $out/s905_autoscript
      cp $out/s905_autoscript $out/boot.scr
      # Le U-Boot vendor charge `emmc_autoscript` sur mmc 1 quand il démarre
      # depuis la eMMC (`start_emmc_autoscript`), et `s905_autoscript` sur mmc 0
      # pour la SD. C'est le même script : il tente déjà mmc 0:1 puis retombe
      # sur mmc 1:1, donc une simple copie suffit.
      cp $out/s905_autoscript $out/emmc_autoscript
      mkimage -A arm64 -O linux -T kernel -C none -a 0x1080000 -e 0x1080000 -n NixOS -d ${kernel}/Image $out/uImage
      # initrd en uImage : c'est ce que le `booti` du vendor accepte (recette Armbian).
      mkimage -A arm64 -O linux -T ramdisk -C gzip -n "NixOS initrd" -d ${initrd} $out/uInitrd
      mkimage -A arm64 -O linux -T multi -C none -a 0x1080000 -e 0x1080000 -n "NixOS multi" -d ${kernel}/Image:${initrd} $out/uImage.multi
    '';
}
