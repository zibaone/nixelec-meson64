# =============================================================================
# Moteur de provisioning — aucune connaissance de famille
#
# Ce fichier est concaténé, dans le script rendu, après :
#   - le plan baké (`plan_*`, `baked_scheme`, `uboot_script`) ;
#   - le provider de plateforme (`platform_*`, `PROVIDER_FAMILY`, `PROTECT_*`,
#     `BOOT_LABEL`).
#
# Il ne contient aucun offset, aucun outil, aucun nom de fichier propre à une
# famille : c'est le contrat de
# `docs/specs/04-contrat-provisioning-plateforme.md`. Tout ce qui est propre à
# une carte est dans le provider ; tout ce qui est propre à une cible est dans
# le plan ; ici, il n'y a que la mécanique.
# =============================================================================

ROOT_MNT=${ROOT_MNT:-/mnt/n5}
disk=${disk:-/dev/mmcblk1}
backup_dir=${backup_dir:-/var/lib/n5-backup}
plan_file=${N5_PLAN:-}
scheme=""
write_bl33=1
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
work="$(mktemp -d /tmp/n5-install.XXXXXX)"

usage() {
  cat <<EOF
usage: install.sh [--vendor|--mainline] [--no-bl33] [--plan FICHIER] [disque] [sauvegarde]

  --vendor    charge utile épinglée sur $BOOT_LABEL (U-Boot d'origine)
  --mainline  extlinux puis chargeur mainline (schéma par défaut : $plan_scheme)
  --no-bl33   mainline seulement : ne pas toucher au chargeur (unité déjà migrée)
  --plan F    plan JSON reçu ; défaut : celui baké dans l'image

défauts : disque=/dev/mmcblk1  sauvegarde=/var/lib/n5-backup
EOF
}

# -----------------------------------------------------------------------------
# Plan : baké dans l'image (variables), ou reçu (`--plan`, JSON).
#
# Le schéma est baké : c'est la seule décision irréversible (écriture du
# chargeur). Un plan reçu ne peut pas le changer — il doit lui être identique,
# et le refus tombe avant tout accès au média.
# -----------------------------------------------------------------------------
load_plan() {
  if [ -n "$plan_file" ]; then
    [ -f "$plan_file" ] || {
      echo "plan absent : $plan_file" >&2
      exit 1
    }
    command -v jq >/dev/null 2>&1 || {
      echo "jq requis pour lire un plan reçu" >&2
      exit 1
    }
    plan_family="$(jq -r '.family // empty' "$plan_file")"
    plan_scheme="$(jq -r '.scheme // empty' "$plan_file")"
    plan_root_label="$(jq -r '.rootLabel // empty' "$plan_file")"
    plan_system="$(jq -r '.system // empty' "$plan_file")"
    plan_dtb="$(jq -r '.dtb // empty' "$plan_file")"
    plan_layout="$(jq -r '.layout // "keep"' "$plan_file")"
    plan_boot_mib="$(jq -r '.bootMib // empty' "$plan_file")"
    for pair in "family:$plan_family" "scheme:$plan_scheme" \
      "rootLabel:$plan_root_label" "system:$plan_system" "dtb:$plan_dtb"; do
      if [ -z "${pair#*:}" ]; then
        echo "plan incomplet : champ '${pair%%:*}' vide" >&2
        exit 1
      fi
    done
    # Le plan est épinglé par son empreinte quand l'appelant la fournit.
    if [ -n "${N5_PLAN_SHA256:-}" ]; then
      got="$(sha256sum "$plan_file" | cut -d' ' -f1)"
      if [ "$got" != "$N5_PLAN_SHA256" ]; then
        echo "refus : plan sha256 '$got', attendu '$N5_PLAN_SHA256'" >&2
        exit 1
      fi
    fi
  fi

  if [ "$plan_family" != "$PROVIDER_FAMILY" ]; then
    echo "refus : plan de famille '$plan_family', image '$PROVIDER_FAMILY'" >&2
    exit 1
  fi
  if [ "$plan_scheme" != "$baked_scheme" ]; then
    echo "refus : plan en schéma '$plan_scheme', image en schéma '$baked_scheme'" >&2
    exit 1
  fi
  case "$plan_system" in
    /nix/store/*) ;;
    *)
      echo "refus : système hors du store : $plan_system" >&2
      exit 1
      ;;
  esac
  if [ "$plan_layout" != "keep" ]; then
    echo "refus : layout '$plan_layout' non supporté par ce moteur (keep seulement)" >&2
    exit 1
  fi
}

parse_args() {
  local positional=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --vendor) scheme=vendor ;;
      --mainline) scheme=mainline ;;
      --no-bl33) write_bl33=0 ;;
      --plan)
        [ $# -ge 2 ] || {
          echo "--plan attend un fichier" >&2
          usage >&2
          exit 2
        }
        plan_file="$2"
        shift
        ;;
      --plan=*) plan_file="${1#*=}" ;;
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
  if [ "${#positional[@]}" -gt 0 ]; then disk="${positional[0]}"; fi
  if [ "${#positional[@]}" -gt 1 ]; then backup_dir="${positional[1]}"; fi
  if [ -z "$scheme" ]; then scheme="$plan_scheme"; fi
}

main() {
  parse_args "$@"
  load_plan

  # Gardes croisées — avant toute lecture/écriture du média.
  echo "schéma : $scheme (cible configurée $plan_scheme)"
  if [ "$scheme" != "$plan_scheme" ]; then
    echo "refus : schéma '$scheme' demandé, cible configurée '$plan_scheme'" >&2
    echo "  changer le schéma demande de changer nixelec.bootloader dans la" >&2
    echo "  configuration de la cible puis de reconstruire l'installateur —" >&2
    echo "  jamais un drapeau à l'appel." >&2
    exit 1
  fi
  if [ "$scheme" = "vendor" ] && [ "$write_bl33" -eq 0 ]; then
    echo "refus : --no-bl33 n'a de sens qu'en schéma mainline" >&2
    exit 1
  fi

  # L'outil de la branche doit être là AVANT le formatage : un outil manquant
  # après le `nixos-install` laisserait une eMMC sans charge utile.
  platform_tools_check

  if [ "${EUID}" -ne 0 ]; then
    echo "run as root" >&2
    exit 1
  fi
  if [ ! -b "$disk" ]; then
    echo "not a block device: $disk" >&2
    exit 1
  fi

  platform_detect
  platform_guard

  root_source="$(findmnt -n -o SOURCE /)"
  root_disk="$(lsblk -n -o PKNAME "$root_source" | head -n 1)"
  if [ "/dev/$root_disk" = "$disk" ]; then
    echo "refusing to install to the running disk $disk" >&2
    exit 1
  fi

  mkdir -p "$backup_dir"
  # Le préfixe protégé est presque entièrement vide : on ne demande que
  # 64 Mio libres, pas sa taille entière.
  avail="$(df -Pm "$backup_dir" | tail -n 1 | tr -s ' ' | cut -d' ' -f4)"
  if [ "${avail:-0}" -lt 64 ]; then
    echo "need at least 64 MiB free in $backup_dir" >&2
    exit 1
  fi

  echo "target: $disk (p1=$p1, p2=$p2)"
  echo "backup: $backup_dir"
  echo "schéma: $scheme ; la charge utile de la cible vient du toplevel installé"
  read -r -p "Type YES to overwrite p1/p2: " answer
  [ "$answer" = "YES" ] || exit 1

  cleanup() {
    umount "$ROOT_MNT/boot" 2>/dev/null || true
    umount "$ROOT_MNT" 2>/dev/null || true
    rm -rf "$work"
  }
  trap cleanup EXIT

  # 1. Sauvegarde AVANT toute écriture (préfixe protégé + médias du chargeur).
  prefix="$backup_dir/prefix-${PROTECT_MIB}MiB-$stamp.img.zst"
  dd if="$disk" bs=1M count="$PROTECT_MIB" status=none | zstd -T0 -3 -q -o "$prefix"
  zstd -t -q "$prefix"
  echo "sauvegarde : $prefix ($(stat -c %s "$prefix") octets)"
  platform_backup_extra

  umount "$p1" 2>/dev/null || true
  umount "$p2" 2>/dev/null || true
  wipefs -a "$p1" "$p2"
  mkfs.vfat -F 32 -n "$BOOT_LABEL" "$p1"
  mkfs.ext4 -L "$plan_root_label" "$p2"

  mkdir -p "$ROOT_MNT"
  mount "$p2" "$ROOT_MNT"
  mkdir -p "$ROOT_MNT/boot"
  mount -o rw "$p1" "$ROOT_MNT/boot"

  # 2. Système cible, dans les deux schémas. `nixos-install` copie la clôture
  # puis joue `switch-to-configuration boot` sur la cible :
  #   - mainline : extlinux écrit `extlinux.conf` et les fichiers de génération ;
  #   - vendor   : aucun chargeur installé, l'avertissement
  #     « do not know how to make this configuration bootable » est normal — la
  #     charge utile est posée juste après, depuis le store de la cible.
  nixos-install --root "$ROOT_MNT" --system "$plan_system" --no-root-passwd

  # L'étiquette posée sur p2 doit être celle que la cible attend dans son
  # fstab. Un écart donnerait un système qui ne trouve pas sa racine au premier
  # démarrage — précisément l'ambiguïté que l'on veut supprimer.
  fstab_label="$(awk '$2 == "/" { n = split($1, a, "/"); print a[n] }' "$ROOT_MNT/etc/fstab")"
  if [ "$fstab_label" != "$plan_root_label" ]; then
    echo "étiquette de racine : fstab='$fstab_label', attendu='$plan_root_label'" >&2
    exit 1
  fi

  platform_write_boot
  platform_verify_boot
  if [ "$scheme" = "mainline" ]; then
    platform_write_bootloader
  fi

  echo "installation terminée (schéma $scheme) ; retirer la carte SD puis démarrer sur la eMMC"
}

# Le script est exécuté sur la carte, mais peut être sourcé par le banc
# (tâche 1.4 du plan) : dans ce cas, on ne lance pas l'installation.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
