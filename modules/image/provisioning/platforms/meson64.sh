# =============================================================================
# Provider meson64 (Amlogic GXL, Magicsee N5)
#
# Tout ce que le moteur n'a pas le droit de connaître : le préfixe protégé, les
# médias du chargeur, la forme des assets d'amorçage, les outils. Le contrat est
# `docs/specs/04-contrat-provisioning-plateforme.md`.
# =============================================================================

PROVIDER_FAMILY=meson64

# Le FIP (secteur 1 → 1 Mio) et l'environnement du U-Boot vendor (628 Mio)
# vivent avant p1 : aucune écriture ne doit les recouvrer, sauf le FIP
# lui-même, explicitement, en dernière étape.
PROTECT_UNTIL=1368064
PROTECT_MIB=668
BOOT_LABEL=NIXOS_BOOT

platform_tools_check() {
  if [ "$plan_scheme" = "vendor" ]; then
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
}

platform_detect() {
  p1="${disk}p1"
  p2="${disk}p2"
  if [ ! -b "$p1" ] || [ ! -b "$p2" ]; then
    echo "expected $p1 and $p2; refusing to repartition" >&2
    exit 1
  fi
}

platform_guard() {
  local start1
  start1="$(cat "/sys/class/block/$(basename "$p1")/start")"
  if [ "$start1" -lt "$PROTECT_UNTIL" ]; then
    echo "$p1 starts before 668 MiB; vendor bootloader is not protected" >&2
    exit 1
  fi
}

platform_backup_extra() {
  local part
  for part in boot0 boot1; do
    if [ -b "${disk}${part}" ]; then
      dd if="${disk}${part}" of="$backup_dir/${part}-$stamp.img" bs=1M status=progress
    fi
  done
}

# -----------------------------------------------------------------------------
# Écriture des assets d'amorçage, depuis le store installé.
# -----------------------------------------------------------------------------
platform_write_boot() {
  if [ "$plan_scheme" = "vendor" ]; then
    # ----------------------------------------------------------------
    # Charge utile épinglée, celle que lit le U-Boot d'origine
    #
    # Elle est produite depuis le toplevel RÉELLEMENT installé, pas depuis les
    # fichiers de cet installateur : `init=`, noyau, initrd et DTB doivent être
    # ceux que `nixos-install` vient de copier dans le store de la cible. Un
    # `init=` figé ici sur un autre toplevel donnerait `Attempted to kill init`
    # au premier démarrage.
    #
    # Le chargeur relit des fichiers à plat sur la FAT et échoue au-delà de
    # ~38 Mo (mesuré : `Bad Data CRC` sur un conteneur de 63 Mo, alors que le
    # fichier du média est conforme). D'où `uImage` et `uInitrd` séparés, et
    # jamais de conteneur multi.
    # ----------------------------------------------------------------
    payload="$work/payload"
    mkdir -p "$payload"
    toplevel="$(readlink -f "$ROOT_MNT/nix/var/nix/profiles/system")"
    case "$toplevel" in
      "$ROOT_MNT"/nix/store/*) ;;
      *)
        echo "profil system de la cible hors de $ROOT_MNT/nix/store : $toplevel" >&2
        exit 1
        ;;
    esac
    for f in init kernel initrd "dtbs/$plan_dtb"; do
      if [ ! -e "$toplevel/$f" ]; then
        echo "toplevel installé sans $f : $toplevel" >&2
        exit 1
      fi
    done
    dtb_base="$(basename "$plan_dtb")"
    cp -L "$toplevel/kernel" "$payload/Image"
    cp -L "$toplevel/initrd" "$payload/initrd"
    cp -L "$toplevel/dtbs/$plan_dtb" "$payload/$dtb_base"

    # Les paramètres viennent du toplevel installé (`kernel-params`) : la
    # console, le CMA et le mode vidéo sont ceux que le noyau de la cible
    # recevra réellement, pas ceux supposés ici.
    bootargs="$(cat "$toplevel/kernel-params") earlycon root=LABEL=$plan_root_label rootwait rw init=$toplevel/init"

    printf 'dtb_name=/%s\nbootargs=%s\n' "$dtb_base" "$bootargs" >"$payload/uEnv.ini"

    # Un autoscript par média, chacun épinglé à son numéro de mmc : le vendor
    # numérote la SD `mmc 0` et la eMMC `mmc 1`. Aucun repli — un script qui
    # tente les deux médias a déjà chargé la charge utile de la SD en démarrant
    # depuis la eMMC (cause mesurée le 31/10).
    local mmc
    for mmc in 0 1; do
      {
        printf 'setenv bootargs "%s"\n' "$bootargs"
        printf 'setenv uimage_addr 0x20000000\n'
        printf 'setenv uinitrd_addr 0x13000000\n'
        printf 'setenv fdt_addr 0x1000000\n'
        printf 'fatload mmc %s:1 ${uimage_addr} uImage\n' "$mmc"
        printf 'fatload mmc %s:1 ${uinitrd_addr} uInitrd\n' "$mmc"
        printf 'fatload mmc %s:1 ${fdt_addr} %s\n' "$mmc" "$dtb_base"
        printf 'echo "Booting NixOS from mmc %s:1"\n' "$mmc"
        printf 'bootm ${uimage_addr} ${uinitrd_addr} ${fdt_addr}\n'
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

    # Pas de `boot.scr` : c'est le script de repli du chargeur mainline, essayé
    # APRÈS `extlinux/extlinux.conf` (mesuré dans `include/config_distro_bootcmd.h`
    # du BL33 : `scan_dev_for_boot` lance `scan_dev_for_extlinux` puis
    # `scan_dev_for_scripts`). Sur une unité vendor il ne serait jamais lu ;
    # après migration, il ferait démarrer une charge utile figée quand extlinux
    # échoue, au lieu d'échouer franchement.
    sync
    cp -f "$payload/Image" "$payload/initrd" "$payload/$dtb_base" \
      "$payload/uImage" "$payload/uInitrd" \
      "$payload/s905_autoscript" "$payload/emmc_autoscript" \
      "$payload/s905_autoscript.txt" "$payload/emmc_autoscript.txt" \
      "$payload/uEnv.ini" "$ROOT_MNT/boot/"
  else
    local conf="$ROOT_MNT/boot/extlinux/extlinux.conf"
    if [ ! -f "$conf" ]; then
      echo "extlinux.conf absent : la cible n'a pas écrit de chargeur" >&2
      exit 1
    fi
    # Forme mesurée du fichier écrit par `extlinux-conf-builder.sh` (nixpkgs) :
    # `  LINUX ../nixos/<hash>-Image`, relatif à `/boot/extlinux`. Le contrôle
    # exigeait `/nixos/` en absolu, ce que le générateur n'écrit jamais :
    # l'installation mainline s'arrêtait ici alors que la configuration était
    # bonne.
    if ! grep -Eq '^  LINUX (\.\./)?/?nixos/' "$conf"; then
      echo "extlinux.conf sans LINUX vers nixos/<génération>" >&2
      exit 1
    fi
    if ! grep -Eq '^  INITRD (\.\./)?/?nixos/' "$conf"; then
      echo "extlinux.conf sans INITRD vers nixos/<génération>" >&2
      exit 1
    fi
    # U-Boot mainline essaie `extlinux/extlinux.conf` d'abord, puis `boot.scr`
    # en repli : un `boot.scr` résiduel ferait démarrer une charge utile figée
    # quand extlinux échoue, au lieu d'échouer franchement. En mainline, elle
    # n'a rien à faire là.
    local f
    for f in boot.scr uImage uInitrd uEnv.ini; do
      if [ -e "$ROOT_MNT/boot/$f" ]; then
        echo "charge utile vendor sur une cible mainline : $f supprimé" >&2
        rm -f "$ROOT_MNT/boot/$f"
      fi
    done
  fi
}

# -----------------------------------------------------------------------------
# Vérification par relecture hors cache. Sans démontage, `cmp` peut valider la
# page cache de l'écriture (défaut déjà constaté sur cette carte).
# -----------------------------------------------------------------------------
platform_verify_boot() {
  if [ "$plan_scheme" = "vendor" ]; then
    payload="$work/payload"
    dtb_base="$(basename "$plan_dtb")"
    toplevel="$(readlink -f "$ROOT_MNT/nix/var/nix/profiles/system")"

    sync
    blockdev --flushbufs "$p1" 2>/dev/null || true
    umount "$ROOT_MNT/boot"
    mount -o ro "$p1" "$ROOT_MNT/boot"
    local f
    for f in Image initrd "$dtb_base" uImage uInitrd \
      s905_autoscript emmc_autoscript \
      s905_autoscript.txt emmc_autoscript.txt uEnv.ini; do
      if ! cmp -s "$payload/$f" "$ROOT_MNT/boot/$f"; then
        echo "relecture différente de l'écrit : $f (charge utile non fiable)" >&2
        exit 1
      fi
    done

    # `init=` doit être le même partout, et égal au profil `system` de la
    # cible : c'est la seule preuve que la charge utile amorce bien le système
    # installé, et pas celui de l'installateur.
    local init_expected="$toplevel/init"
    local profile
    profile="$(readlink -f "$ROOT_MNT/nix/var/nix/profiles/system")"
    if [ "$profile" != "$toplevel" ]; then
      echo "profil system = '$profile', toplevel de la charge utile = '$toplevel'" >&2
      exit 1
    fi
    for f in uEnv.ini s905_autoscript.txt emmc_autoscript.txt; do
      got="$(sed -n 's/.*init=\([^ "]*\).*/\1/p' "$ROOT_MNT/boot/$f" | head -n 1)"
      if [ "$got" != "$init_expected" ]; then
        echo "$f : init='$got', attendu='$init_expected'" >&2
        exit 1
      fi
    done
    echo "charge utile vérifiée : $(ls -1 "$ROOT_MNT/boot" | wc -l) fichiers, init=$init_expected"
  else
    # Vérification de la FAT par relecture : `drop_caches` ne suffit pas tant
    # que la partition est montée, et il faut pousser au média avant de conclure.
    sync
    blockdev --flushbufs "$p1" 2>/dev/null || true
    umount "$ROOT_MNT/boot"
    mount -o ro "$p1" "$ROOT_MNT/boot"
    local kernels
    kernels="$(ls -1 "$ROOT_MNT/boot/nixos" 2>/dev/null | grep -c 'Image$' || true)"
    echo "extlinux installé : $kernels noyau(x) sous /boot/nixos"
    if [ "${kernels:-0}" -lt 1 ]; then
      echo "aucun noyau sous /boot/nixos" >&2
      exit 1
    fi
    umount "$ROOT_MNT/boot"
    mount -o rw "$p1" "$ROOT_MNT/boot"
  fi
}

# -----------------------------------------------------------------------------
# Chargeur seul (migration, ou `--no-bl33` pour conserver celui de l'unité).
# -----------------------------------------------------------------------------
platform_write_bootloader() {
  if [ "$write_bl33" -eq 1 ]; then
    "$uboot_script" "$disk" "$backup_dir" "$stamp"
  else
    echo "--no-bl33 : FIP intact, le chargeur installé est conservé"
  fi
}
