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
  ubootScript = pkgs.writeShellScript "n5-uboot" ''
    set -euo pipefail

    bl33="${n5UbootBl33}/u-boot.bin"
    disk="''${1:-/dev/mmcblk1}"
    backup_dir="''${2:-/var/lib/n5-backup}"
    stamp="''${3:-$(date -u +%Y%m%dT%H%M%SZ)}"
    work="$(mktemp -d /tmp/n5-uboot.XXXXXX)"

    cleanup() { rm -rf "$work"; }
    trap cleanup EXIT

    if [ "''${EUID}" -ne 0 ]; then
      echo "run as root" >&2
      exit 1
    fi
    if [ ! -b "$disk" ]; then
      echo "not a block device: $disk" >&2
      exit 1
    fi
    if [ ! -f "$bl33" ]; then
      echo "BL33 mainline absent du store : $bl33" >&2
      exit 1
    fi

    mkdir -p "$backup_dir"
    avail="$(df -Pm "$backup_dir" | tail -n 1 | tr -s ' ' | cut -d' ' -f4)"
    if [ "''${avail:-0}" -lt 64 ]; then
      echo "need at least 64 MiB free in $backup_dir" >&2
      exit 1
    fi

    # 1. Sauvegarde du préfixe de 668 Mio — sauf si l'appelant vient de la
    # faire (même horodatage). Compressé : la zone est vide à 99,88 %, le
    # fichier fait ~1 Mo au lieu de 668.
    prefix="$backup_dir/prefix-668MiB-$stamp.img.zst"
    if [ -f "$prefix" ] && zstd -t -q "$prefix" 2>/dev/null; then
      echo "sauvegarde déjà présente : $prefix"
    else
      dd if="$disk" bs=1M count=668 status=none | zstd -T0 -3 -q -o "$prefix"
      zstd -t -q "$prefix"
      echo "sauvegarde : $prefix ($(stat -c %s "$prefix") octets)"
    fi

    # 2. Lecture du FIP installé. La ROM vérifie BL1→BL2 et le BL2 porte le DDR
    # init de la carte : les composants viennent donc de CETTE unité, et seul
    # le BL33 change.
    echo "lecture du FIP installé (1 Mio à partir du secteur 1)"
    dd if="$disk" of="$work/installed.bin" bs=512 skip=1 count=2047 status=none
    # gxlimg ne crée pas son dossier de sortie : sans ce mkdir il rend
    # « Cannot open dir … » et le script s'arrête là.
    mkdir -p "$work/installed"
    gxlimg -t fip -e "$work/installed.bin" "$work/installed"
    for f in bl2.sign bl30.enc bl31.enc; do
      if [ ! -f "$work/installed/$f" ]; then
        echo "composant $f introuvable : le FIP installé n'est pas reconnu" >&2
        exit 1
      fi
    done

    # Les composants extraits sont sauvés à part : quelques centaines de Ko qui
    # permettent de reconstruire un FIP sans dépendre du préfixe compressé.
    comps="$backup_dir/components-$stamp"
    mkdir -p "$comps"
    cp -a "$work/installed/bl2.sign" "$work/installed/bl30.enc" \
          "$work/installed/bl31.enc" "$work/installed/bl33.enc" "$comps/" || true
    (
      cd "$comps"
      sha256sum ./* > SHA256SUMS 2>/dev/null || true
      sha256sum "$work/installed.bin" | sed 's| .*|  installed-1MiB-from-sector1.bin|' >> SHA256SUMS
      stat -c '%s %n' ./* > MANIFEST.txt
    )
    echo "composants sauvés : $comps"

    # 3. Candidat : BL2/BL30/BL31 installés + notre BL33.
    gxlimg -t bl3x -c "$bl33" "$work/bl33.enc"
    gxlimg -t fip \
      --bl2 "$work/installed/bl2.sign" \
      --bl30 "$work/installed/bl30.enc" \
      --bl31 "$work/installed/bl31.enc" \
      --bl33 "$work/bl33.enc" \
      "$work/candidate.fip"

    # Contrôle AVANT écriture : ré-extrait du candidat, BL2/BL30/BL31 doivent
    # être identiques aux composants installés. Un écart = aucune écriture.
    mkdir -p "$work/check"
    gxlimg -t fip -e "$work/candidate.fip" "$work/check"
    for f in bl2.sign bl30.enc bl31.enc; do
      if ! cmp -s "$work/installed/$f" "$work/check/$f"; then
        echo "le candidat diffère du FIP installé sur $f — rien n'a été écrit" >&2
        exit 1
      fi
    done

    size="$(stat -c %s "$work/candidate.fip")"
    echo "écriture du BL33 mainline dans $disk (FIP $size octets, secteur 1)"
    dd if="$work/candidate.fip" of="$disk" bs=512 seek=1 conv=fsync,notrunc status=progress

    # Relecture depuis le média : ce que la ROM lira doit être ce qu'on a écrit.
    blocks="$(( (size + 511) / 512 ))"
    dd if="$disk" of="$work/reread.bin" bs=512 skip=1 count="$blocks" status=none
    if ! head -c "$size" "$work/reread.bin" | cmp -s - "$work/candidate.fip"; then
      echo "relecture du FIP différente de l'écrit" >&2
      exit 1
    fi

    echo "BL33 mainline écrit et relu ($(basename "$bl33"))."
    echo "sauvegarde : $prefix"
    echo "restauration du bootloader vendor :"
    echo "  zstd -dc $prefix | dd of=$disk bs=1M conv=fsync,notrunc"
  '';

  installScript = pkgs.writeShellScript "n5-install" ''
    set -euo pipefail

    # ------------------------------------------------------------------
    # Deux schémas d'amorçage, jamais un mélange
    #
    # `vendor`   : charge utile épinglée sur NIXOS_BOOT, lue par le U-Boot
    #              d'origine (autoscripts + uImage/uInitrd à plat) ;
    # `mainline` : extlinux écrit par `nixos-install`, puis BL33 dans le FIP.
    #
    # Le schéma de la cible est figé à la construction (`nixelec.bootloader`
    # de la configuration cible) ; celui demandé à l'appel doit lui être
    # identique. Les deux refus croisés tombent AVANT le premier `dd`.
    # ------------------------------------------------------------------
    target_scheme="${n5TargetBootloader}"
    target_system="${n5TargetSystem}"
    root_label="${n5TargetRootLabel}"
    dtb_name="${n5TargetDtb}"

    disk=/dev/mmcblk1
    backup_dir=/var/lib/n5-backup
    scheme=""
    write_bl33=1
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    work="$(mktemp -d /tmp/n5-install.XXXXXX)"

    usage() {
      cat <<EOF
    usage: install.sh [--vendor|--mainline] [--no-bl33] [disque] [sauvegarde]

      --vendor    charge utile épinglée sur NIXOS_BOOT (U-Boot d'origine)
      --mainline  extlinux puis BL33 mainline (schéma par défaut : $target_scheme)
      --no-bl33   mainline seulement : ne pas toucher au FIP (unité déjà migrée)

    défauts : disque=/dev/mmcblk1  sauvegarde=/var/lib/n5-backup
    EOF
    }

    positional=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --vendor) scheme=vendor ;;
        --mainline) scheme=mainline ;;
        --no-bl33) write_bl33=0 ;;
        -h | --help)
          usage
          exit 0
          ;;
        --)
          shift
          break
          ;;
        -*)
          echo "argument inconnu : $1" >&2
          usage >&2
          exit 2
          ;;
        *) positional+=("$1") ;;
      esac
      shift
    done
    while [ $# -gt 0 ]; do
      positional+=("$1")
      shift
    done
    if [ "''${#positional[@]}" -gt 0 ]; then disk="''${positional[0]}"; fi
    if [ "''${#positional[@]}" -gt 1 ]; then backup_dir="''${positional[1]}"; fi
    if [ -z "$scheme" ]; then scheme="$target_scheme"; fi

    # Gardes croisées — avant toute lecture/écriture du média.
    echo "schéma : $scheme (cible configurée $target_scheme)"
    if [ "$scheme" != "$target_scheme" ]; then
      echo "refus : schéma '$scheme' demandé, cible configurée '$target_scheme'" >&2
      echo "  changer le schéma demande de changer nixelec.bootloader dans la" >&2
      echo "  configuration de la cible puis de reconstruire l'installateur —" >&2
      echo "  jamais un drapeau à l'appel." >&2
      exit 1
    fi
    if [ "$scheme" = "vendor" ] && [ "$write_bl33" -eq 0 ]; then
      echo "refus : --no-bl33 n'a de sens qu'en schéma mainline" >&2
      exit 1
    fi
    # L'outil de la branche doit être là AVANT le formatage : un mkimage
    # manquant après le `nixos-install` laisserait une eMMC sans charge utile.
    if [ "$scheme" = "vendor" ]; then
      if ! command -v mkimage >/dev/null 2>&1; then
        echo "outil manquant pour la charge utile vendor : mkimage (ubootTools)" >&2
        exit 1
      fi
    elif [ "$write_bl33" -eq 1 ]; then
      if ! command -v gxlimg >/dev/null 2>&1; then
        echo "outil manquant pour le BL33 mainline : gxlimg" >&2
        exit 1
      fi
    fi

    if [ "''${EUID}" -ne 0 ]; then
      echo "run as root" >&2
      exit 1
    fi
    if [ ! -b "$disk" ]; then
      echo "not a block device: $disk" >&2
      exit 1
    fi

    p1="''${disk}p1"
    p2="''${disk}p2"
    if [ ! -b "$p1" ] || [ ! -b "$p2" ]; then
      echo "expected $p1 and $p2; refusing to repartition" >&2
      exit 1
    fi

    # Le FIP (secteur 1 → 1 Mio) et l'environnement du U-Boot vendor (628 Mio)
    # vivent avant p1 : aucune écriture ne doit les recouvrer, sauf le FIP
    # lui-même, explicitement, à la fin.
    start1="$(cat "/sys/class/block/$(basename "$p1")/start")"
    if [ "$start1" -lt 1368064 ]; then
      echo "$p1 starts before 668 MiB; vendor bootloader is not protected" >&2
      exit 1
    fi

    root_source="$(findmnt -n -o SOURCE /)"
    root_disk="$(lsblk -n -o PKNAME "$root_source" | head -n 1)"
    if [ "/dev/$root_disk" = "$disk" ]; then
      echo "refusing to install to the running disk $disk" >&2
      exit 1
    fi

    mkdir -p "$backup_dir"
    # Le préfixe de 668 Mio est presque entièrement vide : mesuré à 0,12 %
    # (668 Mio → 821 Kio). On ne demande donc que 64 Mio libres, et non 800.
    avail="$(df -Pm "$backup_dir" | tail -n 1 | tr -s ' ' | cut -d' ' -f4)"
    if [ "''${avail:-0}" -lt 64 ]; then
      echo "need at least 64 MiB free in $backup_dir" >&2
      exit 1
    fi

    echo "target: $disk (p1=$p1, p2=$p2)"
    echo "backup: $backup_dir"
    echo "schéma: $scheme ; la charge utile de la cible vient du toplevel installé"
    read -r -p "Type YES to overwrite p1/p2: " answer
    [ "$answer" = "YES" ] || exit 1

    cleanup() {
      umount /mnt/n5/boot 2>/dev/null || true
      umount /mnt/n5 2>/dev/null || true
      rm -rf "$work"
    }
    trap cleanup EXIT

    # 1. Sauvegarde AVANT toute écriture (préfixe + partitions boot).
    prefix="$backup_dir/prefix-668MiB-$stamp.img.zst"
    dd if="$disk" bs=1M count=668 status=none | zstd -T0 -3 -q -o "$prefix"
    zstd -t -q "$prefix"
    echo "sauvegarde : $prefix ($(stat -c %s "$prefix") octets)"
    for part in boot0 boot1; do
      if [ -b "''${disk}''${part}" ]; then
        dd if="''${disk}''${part}" of="$backup_dir/''${part}-$stamp.img" bs=1M status=progress
      fi
    done

    umount "$p1" 2>/dev/null || true
    umount "$p2" 2>/dev/null || true
    wipefs -a "$p1" "$p2"
    mkfs.vfat -F 32 -n NIXOS_BOOT "$p1"
    mkfs.ext4 -L "$root_label" "$p2"

    mkdir -p /mnt/n5
    mount "$p2" /mnt/n5
    mkdir -p /mnt/n5/boot
    mount -o rw "$p1" /mnt/n5/boot

    # 2. Système cible, dans les deux schémas. `nixos-install` copie la
    # clôture puis joue `switch-to-configuration boot` sur la cible :
    #   - mainline : extlinux écrit `extlinux.conf` et les fichiers de
    #     génération sur p1 ;
    #   - vendor   : aucun chargeur installé, l'avertissement
    #     « do not know how to make this configuration bootable » est normal —
    #     la charge utile est posée juste après, depuis le store de la cible.
    nixos-install --root /mnt/n5 --system "$target_system" --no-root-passwd

    # L'étiquette posée sur p2 doit être celle que la cible attend dans son
    # fstab. Un écart ici donnerait un système installé qui ne trouve pas sa
    # racine au premier démarrage — précisément l'ambiguïté que l'on vient
    # supprimer entre une SD `NIXOS_SD` et la eMMC.
    fstab_label="$(awk '$2 == "/" { n = split($1, a, "/"); print a[n] }' /mnt/n5/etc/fstab)"
    if [ "$fstab_label" != "$root_label" ]; then
      echo "étiquette de racine : fstab='$fstab_label', attendu='$root_label'" >&2
      exit 1
    fi

    if [ "$scheme" = "vendor" ]; then
      # ----------------------------------------------------------------
      # Charge utile épinglée, celle que lit le U-Boot d'origine
      #
      # Elle est produite depuis le toplevel RÉELLEMENT installé, pas depuis
      # les fichiers de cet installateur : `init=`, noyau, initrd et DTB
      # doivent être ceux que `nixos-install` vient de copier dans
      # `/mnt/n5/nix/store`. Un `init=` figé ici sur un autre toplevel
      # donnerait `Attempted to kill init` au premier démarrage.
      #
      # Le chargeur relit des fichiers à plat sur la FAT et échoue au-delà de
      # ~38 Mo (mesuré : `Bad Data CRC` sur un conteneur de 63 Mo, alors que
      # le fichier du média est conforme). D'où `uImage` et `uInitrd` séparés,
      # et jamais de conteneur multi.
      # ----------------------------------------------------------------
      payload="$work/payload"
      mkdir -p "$payload"
      toplevel="$(readlink -f /mnt/n5/nix/var/nix/profiles/system)"
      case "$toplevel" in
        /mnt/n5/nix/store/*) ;;
        *)
          echo "profil system de la cible hors de /mnt/n5/nix/store : $toplevel" >&2
          exit 1
          ;;
      esac
      for f in init kernel initrd "dtbs/$dtb_name"; do
        if [ ! -e "$toplevel/$f" ]; then
          echo "toplevel installé sans $f : $toplevel" >&2
          exit 1
        fi
      done
      dtb_base="$(basename "$dtb_name")"
      cp -L "$toplevel/kernel" "$payload/Image"
      cp -L "$toplevel/initrd" "$payload/initrd"
      cp -L "$toplevel/dtbs/$dtb_name" "$payload/$dtb_base"

      # Les paramètres viennent du toplevel installé (`kernel-params`) : la
      # console, le CMA et le mode vidéo sont ceux que le noyau de la cible
      # recevra réellement, pas ceux supposés ici.
      bootargs="$(cat "$toplevel/kernel-params") earlycon root=LABEL=$root_label rootwait rw init=$toplevel/init"

      printf 'dtb_name=/%s\nbootargs=%s\n' "$dtb_base" "$bootargs" >"$payload/uEnv.ini"

      # Un autoscript par média, chacun épinglé à son numéro de mmc : le
      # vendor numérote la SD `mmc 0` et la eMMC `mmc 1`. Aucun repli —
      # un script qui tente les deux médias a déjà chargé la charge utile de
      # la SD en démarrant depuis la eMMC (cause mesurée le 31/10).
      for mmc in 0 1; do
        {
          printf 'setenv bootargs "%s"\n' "$bootargs"
          printf 'setenv uimage_addr 0x20000000\n'
          printf 'setenv uinitrd_addr 0x13000000\n'
          printf 'setenv fdt_addr 0x1000000\n'
          printf 'fatload mmc %s:1 ''${uimage_addr} uImage\n' "$mmc"
          printf 'fatload mmc %s:1 ''${uinitrd_addr} uInitrd\n' "$mmc"
          printf 'fatload mmc %s:1 ''${fdt_addr} %s\n' "$mmc" "$dtb_base"
          printf 'echo "Booting NixOS from mmc %s:1"\n' "$mmc"
          printf 'bootm ''${uimage_addr} ''${uinitrd_addr} ''${fdt_addr}\n'
        } >"$payload/autoscript-mmc$mmc.txt"
      done
      cp "$payload/autoscript-mmc0.txt" "$payload/s905_autoscript.txt"
      cp "$payload/autoscript-mmc1.txt" "$payload/emmc_autoscript.txt"

      mkimage -A arm64 -O linux -T script -C none -n "N5 boot SD" \
        -d "$payload/s905_autoscript.txt" "$payload/s905_autoscript"
      mkimage -A arm64 -O linux -T script -C none -n "N5 boot eMMC" \
        -d "$payload/emmc_autoscript.txt" "$payload/emmc_autoscript"
      mkimage -A arm64 -O linux -T kernel -C none -a 0x1080000 -e 0x1080000 \
        -n NixOS -d "$payload/Image" "$payload/uImage"
      # `bootm` refuse un initrd cpio brut, d'où l'encapsulation uImage.
      mkimage -A arm64 -O linux -T ramdisk -C gzip -n "NixOS initrd" \
        -d "$payload/initrd" "$payload/uInitrd"

      # Pas de `boot.scr` : c'est le nom que lit le chargeur mainline, avant
      # extlinux. Sur une unité vendor il ne serait jamais lu, et après une
      # migration il masquerait extlinux avec une charge utile figée.
      sync
      cp -f "$payload/Image" "$payload/initrd" "$payload/$dtb_base" \
        "$payload/uImage" "$payload/uInitrd" \
        "$payload/s905_autoscript" "$payload/emmc_autoscript" \
        "$payload/s905_autoscript.txt" "$payload/emmc_autoscript.txt" \
        "$payload/uEnv.ini" /mnt/n5/boot/

      # 2 bis. Relecture hors cache : démonter, remonter en lecture seule,
      # comparer octet par octet. Sans le démontage, `cmp` peut valider la
      # page cache de l'écriture (défaut déjà constaté sur cette carte).
      sync
      blockdev --flushbufs "$p1" 2>/dev/null || true
      umount /mnt/n5/boot
      mount -o ro "$p1" /mnt/n5/boot
      for f in Image initrd "$dtb_base" uImage uInitrd \
        s905_autoscript emmc_autoscript \
        s905_autoscript.txt emmc_autoscript.txt uEnv.ini; do
        if ! cmp -s "$payload/$f" "/mnt/n5/boot/$f"; then
          echo "relecture différente de l'écrit : $f (charge utile non fiable)" >&2
          exit 1
        fi
      done

      # `init=` doit être le même partout, et égal au profil `system` de la
      # cible : c'est la seule preuve que la charge utile amorce bien le
      # système installé, et pas celui de l'installateur.
      init_expected="$toplevel/init"
      profile="$(readlink -f /mnt/n5/nix/var/nix/profiles/system)"
      if [ "$profile" != "$toplevel" ]; then
        echo "profil system = '$profile', toplevel de la charge utile = '$toplevel'" >&2
        exit 1
      fi
      for f in uEnv.ini s905_autoscript.txt emmc_autoscript.txt; do
        got="$(sed -n 's/.*init=\([^ "]*\).*/\1/p' "/mnt/n5/boot/$f" | head -n 1)"
        if [ "$got" != "$init_expected" ]; then
          echo "$f : init='$got', attendu='$init_expected'" >&2
          exit 1
        fi
      done
      echo "charge utile vérifiée : $(ls -1 /mnt/n5/boot | wc -l) fichiers, init=$init_expected"
    else
      conf=/mnt/n5/boot/extlinux/extlinux.conf
      if [ ! -f "$conf" ]; then
        echo "extlinux.conf absent : la cible n'a pas écrit de chargeur" >&2
        exit 1
      fi
      # Forme mesurée du fichier écrit par `extlinux-conf-builder.sh`
      # (nixpkgs) : `  LINUX ../nixos/<hash>-Image`, relatif à
      # `/boot/extlinux`. Le contrôle exigeait `/nixos/` en absolu, ce que le
      # générateur n'écrit jamais : l'installation mainline s'arrêtait ici
      # alors que la configuration était bonne.
      if ! grep -Eq '^  LINUX (\.\./)?/?nixos/' "$conf"; then
        echo "extlinux.conf sans LINUX vers nixos/<génération>" >&2
        exit 1
      fi
      if ! grep -Eq '^  INITRD (\.\./)?/?nixos/' "$conf"; then
        echo "extlinux.conf sans INITRD vers nixos/<génération>" >&2
        exit 1
      fi
      # Une charge utile épinglée sur p1 masquerait extlinux (ce chargeur lit
      # `boot.scr` avant) : en mainline, elle n'a rien à faire là.
      for f in boot.scr uImage uInitrd uEnv.ini; do
        if [ -e "/mnt/n5/boot/$f" ]; then
          echo "charge utile vendor sur une cible mainline : $f supprimé" >&2
          rm -f "/mnt/n5/boot/$f"
        fi
      done

      # Vérification de la FAT par relecture : `drop_caches` ne suffit pas tant
      # que la partition est montée, et il faut pousser au média avant de conclure.
      sync
      blockdev --flushbufs "$p1" 2>/dev/null || true
      umount /mnt/n5/boot
      mount -o ro "$p1" /mnt/n5/boot
      kernels="$(ls -1 /mnt/n5/boot/nixos 2>/dev/null | grep -c 'Image$' || true)"
      echo "extlinux installé : $kernels noyau(x) sous /boot/nixos"
      if [ "''${kernels:-0}" -lt 1 ]; then
        echo "aucun noyau sous /boot/nixos" >&2
        exit 1
      fi
      umount /mnt/n5/boot
      mount -o rw "$p1" /mnt/n5/boot

      # 3. BL33 : une seule implémentation de l'écriture, partagée avec le
      # mode autonome (`/etc/n5/uboot-install.sh`). On lui repasse
      # l'horodatage pour qu'il réutilise la sauvegarde faite à l'étape 1.
      if [ "$write_bl33" -eq 1 ]; then
        ${ubootScript} "$disk" "$backup_dir" "$stamp"
      else
        echo "--no-bl33 : FIP intact, le chargeur installé est conservé"
      fi
    fi

    echo "installation terminée (schéma $scheme) ; retirer la carte SD puis démarrer sur la eMMC"
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
  ];

  system.extraDependencies = [
    n5TargetSystem
    n5UbootBl33
  ];

  environment.etc."n5/install.sh".source = installScript;
  # Remplacement du seul BL33, sans reformater : utilisable sur une carte déjà
  # installée (essai d'un chargeur, retour arrière).
  environment.etc."n5/uboot-install.sh".source = ubootScript;

  services.getty.autologinUser = lib.mkForce "root";
  systemd.services."serial-getty@ttyAML0".enable = true;
}
