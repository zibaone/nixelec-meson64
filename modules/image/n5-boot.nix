{ pkgs, lib }:

{
  mkBootFiles =
    {
      kernel,
      initrd,
      dtbName,
      rootLabel,
      bootParams,
    }:
    let
      dtbBase = builtins.baseNameOf dtbName;
      bootArgs = lib.concatStringsSep " " (
        bootParams
        ++ [
          "root=LABEL=${rootLabel}"
          "rootwait"
          "rw"
        ]
      );
      script = pkgs.writeText "n5-autoscript.txt" ''
        setenv bootargs "${bootArgs}"
        setenv loadaddr 0x1080000
        setenv kernel_addr 0x1080000
        setenv fdtaddr 0x1000000
        setenv fdt_addr 0x1000000
        setenv initrdaddr 0x13000000
        setenv initrd_addr 0x13000000
        setenv uimage_addr 0x20000000
        setenv mmcdev 0
        if fatload mmc 0:1 ''${uimage_addr} uImage.multi; then
          setenv mmcdev 0
        else
          setenv mmcdev 1
          fatload mmc 1:1 ''${uimage_addr} uImage.multi
        fi
        fatload mmc ''${mmcdev}:1 ''${fdt_addr} ${dtbBase}
        echo "Booting NixOS from mmc ''${mmcdev}:1"
        bootm ''${uimage_addr}
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
      mkimage -A arm64 -O linux -T kernel -C none -a 0x1080000 -e 0x1080000 -n NixOS -d ${kernel}/Image $out/uImage
      mkimage -A arm64 -O linux -T multi -C none -a 0x1080000 -e 0x1080000 -n "NixOS multi" -d ${kernel}/Image:${initrd} $out/uImage.multi
    '';
}
