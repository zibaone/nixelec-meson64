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

  # Le plan et le provider sont concaténés au moteur : le script rendu reste un
  # seul fichier, autonome sur la carte, mais il est écrit en trois morceaux
  # (plan baké, provider de famille, mécanique) au lieu d'un monolithe.
  #
  # Contrat : `docs/specs/04-contrat-provisioning-plateforme.md`. Le schéma est
  # baké ici ET dans le plan ; le moteur refuse un plan qui le contredit, et un
  # plan reçu ne peut jamais changer la décision d'écrire le chargeur.
  provider = builtins.readFile ./provisioning/platforms/meson64.sh;
  engine = builtins.readFile ./provisioning/engine.sh;

  installScript = pkgs.writeShellScript "n5-install" ''
    set -euo pipefail

    # ---- plan baké (la cible porte le schéma et l'étiquette) ----------------
    plan_family="meson64"
    plan_board="${config.hardware.nixbian.board}"
    plan_scheme="${n5TargetBootloader}"
    plan_root_label="${n5TargetRootLabel}"
    plan_system="${n5TargetSystem}"
    plan_dtb="${n5TargetDtb}"
    plan_layout="keep"
    plan_boot_mib="488"
    baked_scheme="${n5TargetBootloader}"
    uboot_script="${ubootScript}"

    # ---- provider de plateforme, puis moteur -------------------------------
    ${provider}
    ${engine}
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
    # Lecture d'un plan reçu (`--plan`) ; le plan baké n'en a pas besoin.
    jq
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
