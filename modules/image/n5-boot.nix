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
          # Sans `earlycon`, un plantage avant la sonde de `ttyAML0` est
          # totalement silencieux : la carte reset et ne dit rien. C'est ce que
          # font les autoscripts Armbian pour ces cartes.
          "earlycon"
          "root=LABEL=${rootLabel}"
          "rootwait"
          "rw"
          "init=${toplevel}/init"
        ]
      );

      # Un autoscript par média, chacun épinglé à son numéro de mmc : aucun des
      # deux ne connaît l'autre.
      #
      # Cause mesurée le 31/10 : un script unique, posé à l'identique sous
      # `s905_autoscript` (lu sur mmc 0 = SD) et sous `emmc_autoscript` (lu sur
      # mmc 1 = eMMC), commençait par `fatload mmc 0:1` avant de retomber sur
      # `mmc 1:1`. Démarrée depuis la eMMC avec une SD insérée, la carte
      # chargeait donc la charge utile de la SD. C'est d'autant plus vicieux que
      # les deux médias portent le même `root=LABEL=${rootLabel}` : rien dans le
      # journal ne distingue le système réellement amorcé. Un repli est donc
      # interdit ici — il recréerait exactement ce croisement de médias.
      #
      # Seuil FAT mesuré sur ce chargeur (U-Boot 2015.01 du 16/08/2018) : la
      # lecture d'un fichier de 63 Mo rend des données fausses (« Bad Data CRC »)
      # alors que le fichier est identique au store sur le média, vérifié depuis
      # la carte elle-même ; `uImage` (38 Mo) et `uInitrd` (25 Mo) se relisent
      # avec des CRC identiques. Le seuil est entre 38 et 63 Mo : ne jamais
      # ajouter à cette charge utile un fichier de plus de 38 Mo (l'ancien
      # conteneur `-T multi` noyau+initrd, 63,5 Mo, n'est plus produit pour cette
      # raison).
      # `bootm` refuse un initrd brut, d'où `uInitrd` (initrd encapsulé uImage).
      mkAutoscript =
        mmc:
        pkgs.writeText "n5-autoscript-mmc${builtins.toString mmc}.txt" ''
          setenv bootargs "${bootArgs}"
          setenv uimage_addr 0x20000000
          setenv uinitrd_addr 0x13000000
          setenv fdt_addr 0x1000000
          fatload mmc ${builtins.toString mmc}:1 ''${uimage_addr} uImage
          fatload mmc ${builtins.toString mmc}:1 ''${uinitrd_addr} uInitrd
          fatload mmc ${builtins.toString mmc}:1 ''${fdt_addr} ${dtbBase}
          echo "Booting NixOS from mmc ${builtins.toString mmc}:1"
          bootm ''${uimage_addr} ''${uinitrd_addr} ''${fdt_addr}
        '';

      # `s905_autoscript` : lu par le U-Boot vendor quand il démarre depuis la SD
      # (mmc 0). `emmc_autoscript` : lu quand il démarre depuis la eMMC (mmc 1).
      # `boot.scr` reste une copie de `s905_autoscript` (nom attendu par les
      # chargeurs mainline), et ne doit donc jamais désigner la eMMC.
      sdBootScript = mkAutoscript 0;
      emmcBootScript = mkAutoscript 1;

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
      # Les deux sources lisibles restent sur la FAT : c'est ce qu'on relit au
      # port série (`fatload` + `md`) pour savoir quel script a été exécuté.
      cp ${sdBootScript} $out/s905_autoscript.txt
      cp ${emmcBootScript} $out/emmc_autoscript.txt
      cp ${uEnv} $out/uEnv.ini
      mkimage -A arm64 -O linux -T script -C none -n "N5 boot SD" -d $out/s905_autoscript.txt $out/s905_autoscript
      cp $out/s905_autoscript $out/boot.scr
      mkimage -A arm64 -O linux -T script -C none -n "N5 boot eMMC" -d $out/emmc_autoscript.txt $out/emmc_autoscript
      mkimage -A arm64 -O linux -T kernel -C none -a 0x1080000 -e 0x1080000 -n NixOS -d ${kernel}/Image $out/uImage
      # initrd encapsulé en uImage : c'est la forme que le `bootm` à trois
      # arguments du vendor accepte (recette Armbian).
      mkimage -A arm64 -O linux -T ramdisk -C gzip -n "NixOS initrd" -d ${initrd} $out/uInitrd
    '';
}
