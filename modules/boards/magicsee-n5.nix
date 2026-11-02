{
  config,
  lib,
  ...
}:

{
  hardware.nixbian = {
    board = lib.mkDefault "aml-s9xx-box";
    kernelVendor = lib.mkDefault "edge";
  };

  hardware.deviceTree.name = lib.mkForce "amlogic/meson-gxl-s905x-p212.dtb";

  # LED de façade : bleue quand le système tourne, rouge sinon.
  #
  # Le DT p212 n'a aucun nœud `leds`, et le mainline ne pilote pas la broche :
  # elle reste en entrée, donc la LED reste rouge. Le vendor, lui, la forçait
  # deux fois — `board_init()` du U-Boot 2015.01 écrit
  # `PREG_PAD_GPIO0_O bit 24` (= GPIODV_24) en sortie à 1, et son noyau la
  # reprend via le nœud `/sysled` (`led_gpio = <&gpio GPIODV_24 ...>`, lu par
  # `drivers/amlogic/led/led_sys.c` qui la met aussi à 1 au probe). D'où la
  # régression : remplacer le BL33 a supprimé le seul des deux qui existait
  # encore sous NixOS. Le vendor écrit 1 = bleu ; remettre la broche à 0
  # rallume le rouge. Vérifié sur la carte : `gpio-73 … out hi` et LED bleue.
  #
  # L'overlay rend la LED au noyau (`/sys/class/leds/n5:blue:status`), ce qui
  # la fait passer au bleu à la fin du boot au lieu de dépendre d'un état de
  # broche laissé par le chargeur.
  hardware.deviceTree.filter = lib.mkDefault "meson-gxl-s905x-p212.dtb";
  hardware.deviceTree.overlays = [
    {
      name = "magicsee-n5-led";
      dtsText = ''
        /dts-v1/;
        /plugin/;

        #include <dt-bindings/gpio/gpio.h>
        #include <dt-bindings/gpio/meson-gxl-gpio.h>

        / {
          /* Lu par NixOS (apply_overlays.py) pour décider si l'overlay
             s'applique à ce DT ; en mode plugin, le nœud racine de la source
             n'est pas fusionné dans la base. */
          compatible = "amlogic,p212";

          fragment@0 {
            target-path = "/";

            __overlay__ {
              leds {
                compatible = "gpio-leds";

                led-blue {
                  label = "n5:blue:status";
                  gpios = <&gpio GPIODV_24 GPIO_ACTIVE_HIGH>;
                  default-state = "on";
                };
              };
            };
          };
        };
      '';
    }
  ];

  # VPU stateless meson-amvdec : c'est une capacité de la carte, pas du
  # lecteur. Sans elle, DRMPRIME n'a pas de décodeur à sélectionner et Kodi
  # décode en CPU sans le dire.
  nixelec.vpu.enable = lib.mkDefault true;

  boot.loader.grub.enable = lib.mkForce false;

  # Le BL33 mainline (p212) sait faire de l'extlinux : chaque génération
  # NixOS écrit `extlinux/extlinux.conf` + son noyau et son initrd sous
  # `/boot/nixos/`, et le chargeur les trouve tout seul. C'est ce qui remplace
  # la charge utile épinglée (`boot.scr` + `uImage`/`uInitrd` à plat) et rend
  # `nixos-rebuild switch` maître de l'amorçage — **à une condition, mesurée le
  # 2026-11-01** : `NIXOS_BOOT` doit être monté sur `/boot`. Sans le montage,
  # `switch` écrit dans l'ext4 et la FAT garde l'entrée du dernier `dd` ; c'est
  # le maillon manquant de la Spec 03 (`docs/specs/03-installateur-deux-schemas.md`).
  #
  # `mkDefault` et non `mkForce` : l'image SD (`meson64-sd.nix`) force `false`,
  # parce qu'une SD se démarre encore avec le U-Boot vendor, qui ne connaît
  # pas extlinux.
  boot.loader.generic-extlinux-compatible.enable = lib.mkDefault true;

  # p1 fait 488 Mio et chaque génération y coûte noyau + initrd (~63 Mo,
  # mesurés : Image 38,4 Mio, initrd 24,0 Mio). Sans limite, la septième
  # reconstruction remplit la partition et `nixos-rebuild` échoue en pleine
  # écriture. Trois générations = ~190 Mo, avec de la marge pour le reste.
  boot.loader.generic-extlinux-compatible.configurationLimit = lib.mkForce 3;


  boot.kernelParams = lib.mkForce [
    "console=ttyAML0,115200n8"
    "cma=256M"
    # Sortie HDMI : mode préféré, jamais forcé (`D`). L'EDID d'un téléviseur
    # annonce du 4K que GXL ne compose pas ; panfrost/lima n'y sont pour rien.
    # Côté carte, parce que c'est un fait du boîtier (et non du lecteur).
    "video=HDMI-A-1:1920x1080@60"
  ];
}
