#!/usr/bin/env bash
# =============================================================================
# bench-installateur.sh — banc de l'installateur eMMC Magicsee N5 (Amlogic S905L)
#
# Déroule les points de contrôle C1–C17 du §5 de docs/installateur.md et rend
# un verdict par point : OK / ÉCHEC / À VOIR.
#
# Ce script ne fait QUE de la lecture :
#   * sur l'hôte  : mtools (minfo/mdir/mtype), sfdisk, blkid, zstd, sha256sum,
#                   debugfs — tous en lecture seule ;
#   * sur la N5   : mtype -i /dev/mmcblk1p1, debugfs -R sur /dev/mmcblk1p2,
#                   findmnt, lsblk, hostname, df, cat /proc/uptime.
#   Aucun dd, mkfs, wipefs, fsck réparateur, ni mount en écriture. Les montages
#   de secours sont explicitement `-o ro,noload` (ext4) ou `-o ro` (vfat).
#   L'installation (/etc/n5/install.sh, qui écrit sur la eMMC) n'est JAMAIS
#   lancée par ce script : l'opérateur la tape sur la console, le script se
#   contente d'analyser la trace (C10/C11) et l'état qui en résulte (C12/C13).
#
# Les phases suivent les étapes physiques ; on les joue séparément, dans
# l'ordre, chacune reprenant l'état laissé dans --workdir :
#
#   p0  pré-vol de l'artefact, sur l'hôte, sans carte           → C1, C2
#   p1  carte écrite, dans le lecteur de l'hôte (lecture seule) → C3, C4
#   p2  premier boot de l'installateur (capture UART)           → C5, C6
#   p3  état de la eMMC avant écriture, depuis l'installateur   → C7, C8, C9
#   p4  trace de /etc/n5/install.sh (lancé à la main)           → C10, C11
#   p5  contrôle de p1/p2 de la eMMC après installation         → C12, C13
#   p6  boot depuis la eMMC, SD retirée (capture UART)          → C14, C15, C16
#   p7  second boot eMMC, persistance                           → C17
#   recap  tableau des 17 points et code de sortie
#
# Exemples :
#   ./scripts/bench-installateur.sh --phase p0 --image-zst result-installer/sd-image/*.img.zst
#   ./scripts/bench-installateur.sh --phase p1 --card /dev/sdb
#   ./scripts/bench-installateur.sh --phase p2 --uart /dev/ttyUSB1 --capture-boot 90
#   ./scripts/bench-installateur.sh --phase p3 --uart /dev/ttyUSB1
#   ./scripts/bench-installateur.sh --phase recap
#
# Sortie : 0 si aucun point n'est en ÉCHEC ; 1 sinon ; 2 sur erreur d'usage.
# =============================================================================
set -euo pipefail

readonly PROG=${0##*/}
readonly VERSION=1.0

# --- constantes du protocole (docs/installateur.md §1.2, §1.5, §5) ------------
readonly P1_START_EXPECTED=2048        # 1 MiB
readonly P1_SECTORS=1048576            # 512 MiB
readonly P2_START_EXPECTED=1050624     # 513 MiB
readonly P1_START_MIN=1368064          # 668 MiB — seuil du script d'installation
readonly BACKUP_MIN_MIB=800            # marge exigée dans /var/lib
readonly EXPECTED_FAT_FILES=9
readonly FAT_OFFSET="1M"
readonly PAYLOAD_LABEL="N5_INSTALL"
readonly TARGET_LABEL="NIXOS_SD"
readonly INSTALLER_HOST="n5-installer"
readonly TARGET_HOST="magicsee-n5"

# --- options ----------------------------------------------------------------
PHASE=""
IMAGE=""
IMAGE_ZST=""
CARD=""
UART=""
BAUD=115200
SSH_TARGET=""
TRANSCRIPT=""
CAPTURE_BOOT=0
WORKDIR="${HOME}/.local/state/n5-bench-installateur"
TIMEOUT_CMD=25
COLOR=auto

# --- état global ------------------------------------------------------------
UART_FD_OPEN=""
TRANSPORT=""          # uart | ssh | ""

# =============================================================================
# utilitaires
# =============================================================================
die()  { printf '%s : %s\n' "$PROG" "$*" >&2; exit 2; }
warn() { printf '  ! %s\n' "$*" >&2; }
note() { printf '  · %s\n' "$*"; }

usage() {
  sed -n '2,42p' "$0" | sed 's/^# \{0,1\}//'
  cat <<'EOF'

Options :
  --phase NOM            p0|p1|p2|p3|p4|p5|p6|p7|recap   (obligatoire)
  --image FICHIER        image disque décompressée (.img) pour P0
  --image-zst FICHIER    image .img.zst ; décompressée dans --workdir au besoin
  --card PERIPH          périphérique bloc de la carte SD (ex. /dev/sdb) pour P1
  --uart PERIPH          console série de la N5 (ex. /dev/ttyUSB1)
  --baud N               débit série (défaut 115200, 8N1)
  --ssh [user@]hote      canal de commande SSH au lieu de l'UART (non utilisé
                         par l'image actuelle : ni l'installateur ni la cible
                         n'activent sshd ; gardé pour un banc réseau)
  --transcript FICHIER   trace de console à analyser (P2, P4, P6, P7)
  --capture-boot N       capture N secondes de la console UART puis analyse
  --workdir DIR          état, traces et résultats
                         (défaut ~/.local/state/n5-bench-installateur)
  --timeout N            délai par commande distante, en secondes (défaut 25)
  --no-color             désactive la couleur
  -h, --help             cette aide
EOF
}

color() {  # color CODE TEXTE
  if [ "$COLOR" = always ] || { [ "$COLOR" = auto ] && [ -t 1 ]; }; then
    printf '\033[%sm%s\033[0m' "$1" "$2"
  else
    printf '%s' "$2"
  fi
}

parse_args() {
  while [ $# -gt 0 ]; do
    case $1 in
      --phase)        PHASE=${2:?}; shift 2 ;;
      --image)        IMAGE=${2:?}; shift 2 ;;
      --image-zst)    IMAGE_ZST=${2:?}; shift 2 ;;
      --card)         CARD=${2:?}; shift 2 ;;
      --uart)         UART=${2:?}; shift 2 ;;
      --baud)         BAUD=${2:?}; shift 2 ;;
      --ssh)          SSH_TARGET=${2:?}; shift 2 ;;
      --transcript)   TRANSCRIPT=${2:?}; shift 2 ;;
      --capture-boot) CAPTURE_BOOT=${2:?}; shift 2 ;;
      --workdir)      WORKDIR=${2:?}; shift 2 ;;
      --timeout)      TIMEOUT_CMD=${2:?}; shift 2 ;;
      --no-color)     COLOR=never; shift ;;
      -h|--help)      usage; exit 0 ;;
      *)              die "option inconnue: $1 (voir --help)" ;;
    esac
  done
  [ -n "$PHASE" ] || { usage; die "--phase est obligatoire"; }
  case $PHASE in
    p0|p1|p2|p3|p4|p5|p6|p7|recap) ;;
    *) die "phase inconnue: $PHASE" ;;
  esac
}

require_tools() {
  local missing=()
  for t in "$@"; do command -v "$t" >/dev/null 2>&1 || missing+=("$t"); done
  [ ${#missing[@]} -eq 0 ] || die "outils manquants: ${missing[*]}"
}

# =============================================================================
# résultats
# =============================================================================
# statuts internes : OK | ECHEC | AVOIR  (affichés OK / ÉCHEC / À VOIR)
status_label() {
  case $1 in
    OK)    color 32 "OK" ;;
    ECHEC) color 31 "ÉCHEC" ;;
    AVOIR) color 33 "À VOIR" ;;
    *)     printf '%s' "$1" ;;
  esac
}

record() {  # record ID STATUT MESSAGE
  local id=$1 st=$2 msg=$3 tmp="$WORKDIR/resultats.tsv.tmp"
  mkdir -p "$WORKDIR"
  { [ -f "$WORKDIR/resultats.tsv" ] && grep -v "^${id}	" "$WORKDIR/resultats.tsv" || true; } > "$tmp"
  printf '%s\t%s\t%s\t%s\n' "$id" "$st" "$(date -Is)" "${msg//$'\n'/ | }" >> "$tmp"
  mv "$tmp" "$WORKDIR/resultats.tsv"
  printf '  %-3s %-14s %s\n' "$id" "$(status_label "$st")" "$msg"
}

saved_status() {  # saved_status ID -> dernier statut connu (ou vide)
  [ -f "$WORKDIR/resultats.tsv" ] || { printf ''; return 0; }
  awk -F'\t' -v id="$1" '$1==id { st=$2 } END { printf "%s", st }' "$WORKDIR/resultats.tsv"
}

# =============================================================================
# transport vers la cible (lecture seule)
# =============================================================================
uart_init() {
  [ -n "$UART_FD_OPEN" ] && return 0
  [ -n "$UART" ] || die "aucune console : passer --uart /dev/ttyUSB1 ou --ssh"
  [ -c "$UART" ] || die "pas un périphérique caractère : $UART"
  command -v stty >/dev/null || die "stty introuvable"
  # `clocal` est indispensable : un adaptateur USB-série ne présente pas de
  # DCD, et sans CLOCAL le noyau considère la ligne raccrochée — les lectures
  # passent quand même (on voyait les traces de boot) mais **les écritures sont
  # jetées**, donc aucune commande n'atteint le shell. Symptôme mesuré : les
  # phases p3/p4 rendaient « illisible » alors que la carte répondait.
  stty -F "$UART" "$BAUD" cs8 -cstopb -parenb -crtscts -ixon -ixoff clocal raw -echo \
    || die "stty a échoué sur $UART (droits ? câble ?)"
  exec 9<>"$UART"
  UART_FD_OPEN=1
  TRANSPORT=uart
}

uart_run() {  # uart_run "commande" -> sortie ; 1 si timeout
  local cmd=$1 line deadline out="" rc=1
  local token="@@BENCH-$RANDOM-$RANDOM@@"
  local marker="; echo \"$token\""
  printf '\r%s%s\r' "$cmd" "$marker" >&9
  deadline=$(( SECONDS + TIMEOUT_CMD ))
  while (( SECONDS <= deadline )); do
    if IFS= read -r -t 1 -u 9 line; then
      # La console rend « \r\r\n » : retirer *tous* les \r, sinon les
      # comparaisons échouent et la sortie garde un caractère parasite
      # (mesuré : « racine inattendue (/dev/mmcblk0p2) » alors que la valeur
      # était la bonne).
      line=${line//$'\r'/}
      if [[ $line == "$token" ]]; then rc=0; break; fi
      # La ligne tapée revient préfixée du prompt : la reconnaître par la
      # présence du marqueur, pas par une égalité exacte.
      [[ $line == *"$token"* ]] && continue
      out+="$line"$'\n'
    fi
  done
  printf '%s' "$out"
  return $rc
}

ssh_run() {
  ssh -o BatchMode=yes -o ConnectTimeout="$TIMEOUT_CMD" \
      -o StrictHostKeyChecking=accept-new "$SSH_TARGET" "$1"
}

dev_run() {  # dev_run "commande" — rend la sortie (vide si échec/timeout)
  # Ne rend jamais un code non nul : sous `set -e`, un timeout de console doit
  # produire « illisible » dans le point de contrôle, pas tuer le script.
  case $TRANSPORT in
    uart) uart_run "$1" || true ;;
    ssh)  ssh_run "$1" || true ;;
    *)    true ;;
  esac
}

need_transport() {
  if [ -n "$UART" ]; then uart_init
  elif [ -n "$SSH_TARGET" ]; then TRANSPORT=ssh
  else die "phase $PHASE : --uart PERIPH (ou --ssh) est requis"; fi
}

# capture_boot SECONDES DEST — lit la console pendant N s (power-cycle manuel)
capture_boot() {
  local secs=$1 dest=$2 deadline line
  uart_init
  printf '  → capture de %s s sur %s : mettre la N5 sous tension MAINTENANT\n' \
    "$secs" "$UART" >&2
  deadline=$(( SECONDS + secs ))
  : > "$dest"
  while (( SECONDS < deadline )); do
    if IFS= read -r -t 1 -u 9 line; then
      printf '%s\n' "${line%$'\r'}" >> "$dest"
    fi
  done
  printf '  · trace enregistrée : %s (%s lignes)\n' "$dest" "$(wc -l < "$dest")" >&2
}

get_transcript() {  # get_transcript PHASE -> chemin de la trace normalisée
  local phase=$1 dest="$WORKDIR/transcript-$1.log"
  mkdir -p "$WORKDIR"
  if [ -n "$TRANSCRIPT" ]; then
    [ -f "$TRANSCRIPT" ] || die "trace introuvable : $TRANSCRIPT"
    tr -d '\r' < "$TRANSCRIPT" > "$dest"
  elif [ "${CAPTURE_BOOT:-0}" -gt 0 ]; then
    capture_boot "$CAPTURE_BOOT" "$dest"
  elif [ -s "$dest" ]; then
    note "réutilise la trace existante $dest"
  else
    die "phase $phase : fournir --capture-boot N (UART branché) ou --transcript FICHIER"
  fi
  printf '%s' "$dest"
}

# =============================================================================
# mtools : lecture de la FAT32, jamais d'écriture
# =============================================================================
fat_spec_image() { printf '%s@@%s' "$1" "$FAT_OFFSET"; }

fat_list() {  # fat_list SPEC -> noms longs triés (un par ligne)
  mdir -b -i "$1" ::/ 2>/dev/null | sed 's|^::/||' | sort
}

fat_label() {  # fat_label SPEC -> étiquette de volume
  minfo -i "$1" :: 2>/dev/null | sed -n 's/^disk label="\(.*\)"$/\1/p' | sed 's/ *$//'
}

fat_text() {   # fat_text SPEC CHEMIN -> contenu du fichier
  mtype -i "$1" "::$2" 2>/dev/null
}

part_dev() {   # part_dev /dev/sdb 1 -> /dev/sdb1 ; /dev/mmcblk0 1 -> p1
  case $1 in
    *[0-9]) printf '%sp%s' "$1" "$2" ;;
    *)      printf '%s%s' "$1" "$2" ;;
  esac
}

sfdisk_geom() {  # sfdisk_geom FICHIER -> "p1_start p1_size p2_start p2_size"
  sfdisk -d "$1" 2>/dev/null | awk -F'[:=,]' '
    /start=/ {
      n++; s=$3; z=$5; gsub(/[^0-9]/, "", s); gsub(/[^0-9]/, "", z)
      if (n == 1) { p1s = s; p1z = z } else if (n == 2) { p2s = s; p2z = z }
    }
    END { printf "%s %s %s %s\n", p1s, p1z, p2s, p2z }'
}

blkid_export() {  # blkid_export DEV -> "LABEL=… TYPE=…" (chaîne vide si illisible)
  local out
  out=$(blkid -p -o export "$1" 2>/dev/null || true)
  printf 'LABEL=%s TYPE=%s' \
    "$(printf '%s\n' "$out" | sed -n 's/^LABEL=//p')" \
    "$(printf '%s\n' "$out" | sed -n 's/^TYPE=//p')"
}

# =============================================================================
# P0 — pré-vol de l'artefact, sur l'hôte, sans carte
# =============================================================================
ensure_image() {
  local out="$WORKDIR/n5-installer.img"
  if [ -n "$IMAGE" ]; then
    case $IMAGE in
      *.zst) die "--image attend l'image décompressée ; $IMAGE est un .zst (utiliser --image-zst)" ;;
    esac
    [ -f "$IMAGE" ] || die "image introuvable : $IMAGE"
    printf '%s' "$IMAGE"
  elif [ -n "$IMAGE_ZST" ]; then
    [ -f "$IMAGE_ZST" ] || die "image compressée introuvable : $IMAGE_ZST"
    if [ ! -f "$out" ] || [ "$IMAGE_ZST" -nt "$out" ]; then
      printf '  · décompression de %s vers %s\n' "$IMAGE_ZST" "$out" >&2
      zstd -dc --no-progress "$IMAGE_ZST" > "$out.tmp"
      mv "$out.tmp" "$out"
    fi
    printf '%s' "$out"
  elif [ -f "$out" ]; then
    printf '%s' "$out"
  else
    die "P0 a besoin de --image FICHIER ou --image-zst FICHIER"
  fi
}

phase_p0() {
  require_tools mdir mtype minfo sfdisk blkid sha256sum awk sed zstd
  local img spec label count missing=() dtb f
  img=$(ensure_image)
  mkdir -p "$WORKDIR"
  spec=$(fat_spec_image "$img")

  printf '\n== P0 — pré-vol de l’artefact (hôte, sans carte) ==\n'
  note "image        : $img"
  note "taille       : $(stat -c %s "$img") octets ($(awk -v s="$(stat -c %s "$img")" 'BEGIN{printf "%.2f GiB", s/1073741824}'))"
  note "sha256 image : $(sha256sum "$img" | cut -d' ' -f1)"
  if [ -n "$IMAGE_ZST" ] && [ -f "$IMAGE_ZST" ]; then
    note "sha256 .zst  : $(sha256sum "$IMAGE_ZST" | cut -d' ' -f1)"
    note "zstd -l      : $(zstd -l "$IMAGE_ZST" | awk 'NR==2{printf "%s compressé → %s décompressé (ratio %s)", $3" "$4, $5" "$6, $7}')"
  fi

  # --- table de partitions ---------------------------------------------------
  local p1_start p1_size p2_start p2_size
  read -r p1_start p1_size p2_start p2_size < <(sfdisk_geom "$img")
  note "p1           : start=${p1_start:-?} size=${p1_size:-?} (attendu ${P1_START_EXPECTED}/${P1_SECTORS})"
  note "p2           : start=${p2_start:-?} size=${p2_size:-?} (attendu ${P2_START_EXPECTED})"
  if [ "${p1_start:-0}" != "$P1_START_EXPECTED" ] || [ "${p1_size:-0}" != "$P1_SECTORS" ] \
     || [ "${p2_start:-0}" != "$P2_START_EXPECTED" ]; then
    warn "géométrie différente de docs/installateur.md §1.2 — à signaler, pas bloquant pour C1/C2"
  fi

  # --- étiquette ext4 de p2 (preuve que le rootfs est là) --------------------
  dd if="$img" of="$WORKDIR/p2-head.img" bs=512 skip="$P2_START_EXPECTED" count=16384 status=none
  note "p2 blkid     : $(blkid_export "$WORKDIR/p2-head.img")"

  # --- C1 : contenu de la FAT ------------------------------------------------
  label=$(fat_label "$spec")
  fat_list "$spec" > "$WORKDIR/p0-fat.txt"
  mdir -i "$spec" -/ ::/ > "$WORKDIR/p0-fat-long.txt" 2>/dev/null || true
  count=$(grep -c . "$WORKDIR/p0-fat.txt" || true)

  for f in boot.scr uImage.multi uEnv.ini s905_autoscript s905_autoscript.txt \
           uImage Image initrd; do
    grep -qx "$f" "$WORKDIR/p0-fat.txt" || missing+=("$f")
  done
  # le DTB est nommé par uEnv.ini : on le vérifie via dtb_name=
  dtb=$(fat_text "$spec" /uEnv.ini | sed -n 's/^dtb_name=\/*//p' | tr -d '\r')
  if [ -n "$dtb" ]; then
    grep -qx "$dtb" "$WORKDIR/p0-fat.txt" || missing+=("$dtb")
  else
    missing+=("dtb_name= absent d'uEnv.ini")
  fi

  note "volume FAT   : ${label:-<vide>}"
  note "fichiers     : $count (attendu $EXPECTED_FAT_FILES)"
  note "occupation   : $(awk '/ files .* bytes/{print $(NF-3)" "$(NF-2)" "$(NF-1)" "$NF}' "$WORKDIR/p0-fat-long.txt" 2>/dev/null | head -1)"

  if [ "$label" = "N5_BOOT" ] && [ "$count" -eq "$EXPECTED_FAT_FILES" ] && [ ${#missing[@]} -eq 0 ]; then
    record C1 OK "volume N5_BOOT, $count fichiers, charge utile complète"
  else
    record C1 ECHEC "volume='${label:-?}' fichiers=$count manquants=${missing[*]:-aucun}"
  fi

  # --- C2 : uEnv.ini de l'installateur --------------------------------------
  local uenv init_path root_lbl
  uenv=$(fat_text "$spec" /uEnv.ini)
  init_path=$(printf '%s\n' "$uenv" | sed -n 's/.*init=\([^ ]*\).*/\1/p')
  root_lbl=$(printf '%s\n' "$uenv" | sed -n 's/.*root=LABEL=\([^ ]*\).*/\1/p')
  note "uEnv.ini     : $(printf '%s' "$uenv" | wc -c) octets"
  note "root=        : ${root_lbl:-<absent>}"
  note "init=        : ${init_path:-<absent>}"
  if [ -n "$init_path" ] && [ "${init_path##*/}" = init ] \
     && [ "$root_lbl" = "$PAYLOAD_LABEL" ] && [ "${init_path#/nix/store/}" != "$init_path" ]; then
    record C2 OK "init= non vide et root=LABEL=$PAYLOAD_LABEL"
  else
    record C2 ECHEC "init= '${init_path:-absent}' / root '${root_lbl:-absent}' — artefact périmé, ne pas flasher"
  fi

  # --- informations complémentaires (hors C1..C17) --------------------------
  local hdr
  if command -v python3 >/dev/null 2>&1 && command -v mcopy >/dev/null 2>&1; then
    mcopy -o -i "$spec" ::/uImage.multi "$WORKDIR/uImage.multi" 2>/dev/null || true
    if [ -f "$WORKDIR/uImage.multi" ]; then
      hdr=$(python3 - "$WORKDIR/uImage.multi" <<'PY'
import struct, sys, os
p = sys.argv[1]
h = open(p, 'rb').read(64)
m, hc, ts, size, load, ep, dc, osi, arch, typ, comp = struct.unpack('>IIIIIIIBBBB', h[:32])
name = h[32:64].split(b'\0')[0].decode()
types = {2: "kernel", 3: "ramdisk", 4: "multi", 6: "script"}
lens, off = [], 64
while True:
    (n,) = struct.unpack('>I', open(p, 'rb').read(off + 4)[off:off + 4])
    if n == 0:
        break
    lens.append(n); off += 4
print("magic=%#x type=%s arch=%d comp=%d name=%r taille=%d composants=%s taille_fichier=%d"
      % (m, types.get(typ, typ), arch, comp, name, size, lens, os.path.getsize(p)))
PY
)
      note "uImage.multi : $hdr"
    fi
  else
    note "uImage.multi : en-tête non analysé (python3 absent)"
  fi
  note "résultats    : $WORKDIR/resultats.tsv"
}

# =============================================================================
# P1 — carte écrite, dans le lecteur de l'hôte (lecture seule)
# =============================================================================
guard_card_readonly() {  # refuse le disque système, avertit si monté
  local card=$1 root_src root_disk
  [ -b "$card" ] || die "pas un périphérique bloc : $card (attendu /dev/sdX)"
  root_src=$(findmnt -n -o SOURCE / || true)
  # remonte la chaîne (LUKS/LVM → partition → disque) jusqu'au disque physique
  root_disk=$(lsblk -snro NAME "$root_src" 2>/dev/null | tail -n 1 || true)
  if [ -n "$root_disk" ] && [ "$card" = "/dev/$root_disk" ]; then
    die "refus : $card porte la racine de l'hôte (/dev/$root_disk)"
  fi
  if grep -q "^${card}" /proc/mounts 2>/dev/null; then
    warn "$card (ou une de ses partitions) est monté — lecture seule, mais démonter évite toute course"
  fi
  if [ -n "$(lsblk -n -o MOUNTPOINTS "$card" 2>/dev/null | tr -d ' ')" ]; then
    warn "points de montage actifs sur $card (voir lsblk)"
  fi
}

phase_p1() {
  require_tools mdir blkid sfdisk lsblk findmnt
  [ -n "$CARD" ] || die "phase p1 : --card /dev/sdX est requis"
  guard_card_readonly "$CARD"
  local p1 p2 l1 l2 count
  p1=$(part_dev "$CARD" 1); p2=$(part_dev "$CARD" 2)

  printf '\n== P1 — contrôle de la carte écrite (lecture seule) ==\n'
  note "périphérique : $CARD"
  lsblk -b -o NAME,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS "$CARD" 2>/dev/null | sed 's/^/    /' || true

  # géométrie (info)
  local g_p1_start g_p1_size g_p2_start g_p2_size
  read -r g_p1_start g_p1_size g_p2_start g_p2_size < <(sfdisk_geom "$CARD")
  note "p1 start/size : ${g_p1_start:-?} ${g_p1_size:-?} (attendu ${P1_START_EXPECTED} ${P1_SECTORS})"
  note "p2 start/size : ${g_p2_start:-?} ${g_p2_size:-?} (attendu ${P2_START_EXPECTED})"

  # --- C3 : étiquettes et types de systèmes de fichiers ----------------------
  l1=$(blkid_export "$p1")
  l2=$(blkid_export "$p2")
  note "p1 : ${l1}"
  note "p2 : ${l2}"
  if [ "$l1" = "LABEL=N5_BOOT TYPE=vfat" ] && [ "$l2" = "LABEL=N5_INSTALL TYPE=ext4" ]; then
    record C3 OK "p1 N5_BOOT/vfat, p2 N5_INSTALL/ext4"
  else
    record C3 ECHEC "p1='${l1:-vide}' p2='${l2:-vide}' — .img.zst écrit sans zstd -dc ?"
  fi

  # --- C4 : contenu de p1 identique à P0 ------------------------------------
  if mdir -b -i "$p1" ::/ >/dev/null 2>&1; then
    count=$(mdir -b -i "$p1" ::/ 2>/dev/null | sed 's|^::/||' | grep -c . || true)
    if [ -f "$WORKDIR/p0-fat-long.txt" ]; then
      if diff -q "$WORKDIR/p0-fat-long.txt" <(mdir -i "$p1" -/ ::/ 2>/dev/null) >/dev/null; then
        record C4 OK "$count fichiers, listing identique à P0"
      else
        record C4 ECHEC "listing de p1 différent de P0 (voir diff -u $WORKDIR/p0-fat-long.txt <(mdir -i $p1 -/ ::/))"
      fi
    else
      if [ "$count" -eq "$EXPECTED_FAT_FILES" ]; then
        record C4 AVOIR "$count fichiers (P0 non joué : comparaison impossible)"
      else
        record C4 ECHEC "$count fichiers au lieu de $EXPECTED_FAT_FILES"
      fi
    fi
  else
    record C4 ECHEC "p1 illisible en FAT (partition absente ou non formatée)"
  fi
}

# =============================================================================
# P2 — premier boot de l'installateur
# =============================================================================
phase_p2() {
  local t host
  t=$(get_transcript p2)
  printf '\n== P2 — premier boot de l’installateur ==\n'
  note "trace : $t"

  if grep -q "Booting NixOS from mmc 0:1" "$t"; then
    record C5 OK "« Booting NixOS from mmc 0:1 » — démarrage sur la SD"
  else
    record C5 ECHEC "séquence « mmc 0:1 » absente (voir $t ; E16 si la console est muette)"
  fi

  host=""
  if [ -n "$UART" ] || [ -n "$SSH_TARGET" ]; then
    need_transport
    host=$(dev_run "hostname" | tr -d ' \r' | tail -n 1)
  fi
  [ -n "$host" ] || host=$(grep -oE '\[root@[a-z0-9-]+' "$t" | tail -n 1 | sed 's/\[root@//')
  note "hôte         : ${host:-<inconnu>}"
  if [ "$host" = "$INSTALLER_HOST" ]; then
    record C6 OK "invite $INSTALLER_HOST — on est dans l'installateur"
  elif [ -z "$host" ]; then
    record C6 AVOIR "invite non observée (brancher --uart pour interroger la cible)"
  else
    record C6 ECHEC "hôte '$host' au lieu de $INSTALLER_HOST — on a démarré ailleurs"
  fi
}

# =============================================================================
# P3 — état de la eMMC avant écriture, depuis l'installateur
# =============================================================================
phase_p3() {
  need_transport
  printf '\n== P3 — état avant écriture, depuis l’installateur ==\n'

  local root_src start free init tb u
  root_src=$(dev_run "findmnt -n -o SOURCE /" | tr -d '\r' | tail -n 1)
  note "racine       : ${root_src:-<inconnu>} (attendu /dev/mmcblk0p2)"
  case $root_src in
    /dev/mmcblk0p2) ;;
    /dev/mmcblk1*)  warn "on tourne sur la eMMC : E6, le script d'installation refusera" ;;
    "")             warn "findmnt n'a rien rendu — console indisponible ?" ;;
    *)              warn "racine inattendue ($root_src)" ;;
  esac

  # --- C7 : offset de p1 -----------------------------------------------------
  start=$(dev_run "cat /sys/class/block/mmcblk1p1/start" | tr -d '\r' | tail -n 1 | tr -d ' ')
  case $start in ''|*[!0-9]*) start="" ;; esac
  note "start(p1)    : ${start:-<illisible>} (seuil $P1_START_MIN)"
  if [ -n "$start" ] && [ "$start" -ge "$P1_START_MIN" ]; then
    record C7 OK "start(p1)=$start ≥ $P1_START_MIN (zone vendor 668 MiB protégée)"
  elif [ -z "$start" ]; then
    record C7 AVOIR "start(p1) illisible (p1 absente ou console muette : E4/E5)"
  else
    record C7 ECHEC "start(p1)=$start < $P1_START_MIN — E3, ne pas lancer l'installation"
  fi

  # --- C8 : clôture de la cible présente dans le store de l'installateur ----
  tb=$(dev_run "readlink -f /etc/n5/target-boot" | tr -d '\r' | tail -n 1)
  note "target-boot  : ${tb:-<absent>}"
  if [ -n "$tb" ]; then
    u=$(dev_run "cat $tb/uEnv.ini")
    init=$(printf '%s\n' "$u" | sed -n 's/.*init=\([^ ]*\).*/\1/p' | tr -d '\r')
  else
    init=""
  fi
  note "init= cible  : ${init:-<absent>}"
  if [ -n "$init" ] && [ "$(dev_run "test -x $init && echo OUI || echo NON" | tr -dc 'A-Z')" = OUI ]; then
    record C8 OK "système cible présent et exécutable dans le store ($(basename "$(dirname "$init")"))"
  elif [ -n "$init" ]; then
    record C8 ECHEC "$init absent du store de l'installateur — E9, nixos-install échouera"
  else
    record C8 AVOIR "/etc/n5/target-boot illisible — vérifier à la main"
  fi

  # --- C9 : marge pour la sauvegarde ----------------------------------------
  free=$(dev_run "df -Pm /var/lib | tail -n 1" | tr -s ' ' | tr -d '\r' | tail -n 1 | cut -d' ' -f4)
  case $free in ''|*[!0-9]*) free="" ;; esac
  note "libre /var/lib: ${free:-<inconnu>} MiB (seuil $BACKUP_MIN_MIB)"
  if [ -n "$free" ] && [ "$free" -ge "$BACKUP_MIN_MIB" ]; then
    record C9 OK "$free MiB libres ≥ $BACKUP_MIN_MIB"
  elif [ -z "$free" ]; then
    record C9 AVOIR "df illisible"
  else
    record C9 ECHEC "$free MiB < $BACKUP_MIN_MIB — E7 : expand-root-partition n'a pas tourné, ne pas forcer"
  fi
}

# =============================================================================
# P4 — trace de /etc/n5/install.sh (lancé à la main par l'opérateur)
# =============================================================================
phase_p4() {
  local t sig=""
  t=$(get_transcript p4)
  printf '\n== P4 — installation (trace de console) ==\n'
  note "trace : $t"

  # signatures d'échec du §6, dans l'ordre où le script les produit
  for pat in "starts before 668 MiB" "refusing to repartition" "not a block device" \
             "refusing to install to the running disk" "need at least 800 MiB" \
             "No space left on device" "is not valid" "should have permissions"; do
    if grep -qF "$pat" "$t"; then sig=$pat; break; fi
  done

  if [ -n "$sig" ]; then
    record C10 ECHEC "signature d'échec « $sig » (voir §6 de docs/installateur.md)"
  elif grep -qF "installation finished!" "$t"; then
    if grep -qF "do not know how to make this configuration bootable" "$t"; then
      record C10 OK "« installation finished! » + avertissement chargeur (normal, attendu)"
    else
      record C10 AVOIR "« installation finished! » sans l'avertissement chargeur attendu"
    fi
  elif [ -s "$t" ]; then
    record C10 ECHEC "« installation finished! » absent de la trace (installation interrompue ?)"
  else
    record C10 AVOIR "trace vide"
  fi

  # --- C11 : plus aucun montage sous /mnt/n5 --------------------------------
  if [ -n "$UART" ] || [ -n "$SSH_TARGET" ]; then
    need_transport
    local mnt
    mnt=$(dev_run "findmnt -rn -o TARGET /mnt/n5 /mnt/n5/boot" | tr -d '\r' | tr '\n' ' ')
    if [ -z "$(printf '%s' "$mnt" | tr -d ' ')" ]; then
      record C11 OK "aucun montage résiduel sous /mnt/n5 (trap exécuté)"
    else
      record C11 ECHEC "montages résiduels : $mnt"
    fi
  else
    record C11 AVOIR "pas de console pour vérifier les montages — relancer p4 avec --uart"
  fi
}

# =============================================================================
# P5 — contrôle de p1/p2 de la eMMC après installation (strictement en lecture)
# =============================================================================
read_emmc_fat() {  # read_emmc_fat CHEMIN_DANS_P1
  local out
  out=$(dev_run "command -v mtype >/dev/null && mtype -i /dev/mmcblk1p1 ::$1")
  if [ -n "$out" ]; then
    printf '%s' "$out"
    return 0
  fi
  # secours : montage vfat en lecture seule sur tmpfs
  dev_run "mkdir -p /run/n5bench/p1 && mount -o ro /dev/mmcblk1p1 /run/n5bench/p1 && cat /run/n5bench/p1$1; umount /run/n5bench/p1"
}

phase_p5() {
  need_transport
  printf '\n== P5 — contrôle de la eMMC après installation ==\n'

  # --- C12 : charge utile installée = celle de la cible ---------------------
  local uenv root_lbl init_path
  uenv=$(read_emmc_fat /uEnv.ini | tr -d '\r')
  root_lbl=$(printf '%s\n' "$uenv" | sed -n 's/.*root=LABEL=\([^ ]*\).*/\1/p')
  init_path=$(printf '%s\n' "$uenv" | sed -n 's/.*init=\([^ ]*\).*/\1/p')
  note "root=        : ${root_lbl:-<absent>}"
  note "init=        : ${init_path:-<absent>}"
  if [ "$root_lbl" = "$TARGET_LABEL" ] && [ -n "$init_path" ] \
     && [ "${init_path#*nixos-system-}" != "$init_path" ] \
     && [ "${init_path#*n5-installer}" = "$init_path" ]; then
    record C12 OK "root=LABEL=$TARGET_LABEL et init=…-nixos-system-… (pas l'installateur)"
  elif [ -z "$uenv" ]; then
    record C12 AVOIR "uEnv.ini de p1 illisible — vérifier à la main (mtype/debugfs)"
  else
    record C12 ECHEC "root='${root_lbl:-absent}' init='${init_path:-absent}' — E12 : la cible ne démarrera pas"
  fi

  # --- C13 : le profil system résout dans le store de p2 --------------------
  local link target
  link=$(dev_run "debugfs -R 'stat /nix/var/nix/profiles/system' /dev/mmcblk1p2 2>/dev/null | sed -n 's/^Fast link dest: //p'" | tr -d '\r' | tr -d '"' | tail -n 1)
  link=${link#Fast link dest: }
  [ -n "$link" ] || link=$(dev_run "mkdir -p /run/n5bench/p2 && mount -o ro,noload /dev/mmcblk1p2 /run/n5bench/p2 && readlink -f /run/n5bench/p2/nix/var/nix/profiles/system; umount /run/n5bench/p2" | tr -d '\r' | tail -n 1)
  target=${link#/run/n5bench/p2}
  note "profil system: ${target:-<introuvable>}"
  if [ -n "$target" ] && [ "${target#/nix/store/}" != "$target" ] \
     && [ "$(dev_run "debugfs -R 'stat $target/init' /dev/mmcblk1p2 2>/dev/null | grep -c 'Type: regular'" | tr -dc '0-9')" != "0" ]; then
    record C13 OK "profil → $target, présent dans /nix/store de p2"
  elif [ -z "$target" ]; then
    record C13 ECHEC "profil system illisible — la clôture n'a pas été copiée (E13)"
  else
    record C13 ECHEC "$target absent du store de p2 — init introuvable (E13)"
  fi
}

# =============================================================================
# P6 — boot depuis la eMMC, SD retirée
# =============================================================================
phase_p6() {
  local t host src names
  t=$(get_transcript p6)
  printf '\n== P6 — boot depuis la eMMC (SD retirée) ==\n'
  note "trace : $t"

  if grep -q "Booting NixOS from mmc 1:1" "$t"; then
    record C14 OK "« Booting NixOS from mmc 1:1 » — branche de repli de l'autoscript exercée"
  elif grep -q "Booting NixOS from mmc 0:1" "$t"; then
    record C14 ECHEC "la SD est encore en place (mmc 0:1) — E14, retirer la carte et refaire p6"
  else
    record C14 ECHEC "aucune ligne « Booting NixOS from mmc … » — E11 (hypothèse U-Boot non vérifiée)"
  fi

  need_transport
  src=$(dev_run "findmnt -n -o SOURCE /" | tr -d '\r' | tail -n 1)
  names=$(dev_run "lsblk -dn -o NAME" | tr -d '\r' | tr '\n' ' ')
  note "racine       : ${src:-<inconnu>} (attendu /dev/mmcblk1p2)"
  note "disques      : ${names:-<inconnu>}"
  if [ "$src" = "/dev/mmcblk1p2" ] && [ "${names#*mmcblk0}" = "$names" ]; then
    record C15 OK "racine /dev/mmcblk1p2 et aucun mmcblk0 (SD absente)"
  elif [ "$src" = "/dev/mmcblk0p2" ]; then
    record C15 ECHEC "racine /dev/mmcblk0p2 — on a démarré sur la SD (E15 : deux NIXOS_SD ?)"
  else
    record C15 ECHEC "racine '${src:-?}' / disques '${names:-?}' — boot eMMC non prouvé"
  fi

  host=$(dev_run "hostname" | tr -d ' \r' | tail -n 1)
  note "hôte         : ${host:-<inconnu>}"
  if [ "$host" = "$TARGET_HOST" ]; then
    record C16 OK "invite $TARGET_HOST — c'est la cible, pas l'installateur"
  else
    record C16 ECHEC "hôte '${host:-?}' au lieu de $TARGET_HOST"
  fi
}

# =============================================================================
# P7 — persistance : second boot eMMC
# =============================================================================
phase_p7() {
  local t prev up
  t=$(get_transcript p7)
  printf '\n== P7 — persistance (second boot eMMC) ==\n'
  note "trace : $t"

  if [ -s "$WORKDIR/transcript-p6.log" ]; then
    prev=$(mktemp)
    grep -E "Booting NixOS from mmc|Kernel command line|Starting kernel" \
      "$WORKDIR/transcript-p6.log" > "$prev" || true
    if grep -q "Booting NixOS from mmc 1:1" "$t" \
       && diff -q "$prev" <(grep -E "Booting NixOS from mmc|Kernel command line|Starting kernel" "$t") >/dev/null; then
      note "séquence de boot identique à P6"
      up=""
      if [ -n "$UART" ] || [ -n "$SSH_TARGET" ]; then
        need_transport
        up=$(dev_run "cat /proc/uptime | cut -d' ' -f1" | tr -d '\r' | tail -n 1)
      fi
      note "uptime       : ${up:-<non interrogé>} s"
      case $up in ''|*[!0-9.]*) up="" ;; esac
      if [ -n "$up" ] && awk -v u="$up" 'BEGIN{exit !(u < 300)}'; then
        record C17 OK "second boot eMMC identique, uptime ${up}s (reparti de zéro)"
      elif [ -z "$up" ]; then
        record C17 AVOIR "boot identique mais uptime non interrogé (ajouter --uart)"
      else
        record C17 ECHEC "uptime ${up}s : la machine n'a pas redémarré"
      fi
    else
      record C17 ECHEC "séquence de boot différente de P6 (voir diff des traces)"
    fi
    rm -f "$prev"
  else
    record C17 AVOIR "trace P6 absente : jouer p6 avant p7"
  fi
}

# =============================================================================
# récapitulatif
# =============================================================================
phase_recap() {
  local id st n_ok=0 n_echec=0 n_avoir=0 n_joue=0 premier=""
  printf '\n== Récapitulatif — points de contrôle C1..C17 ==\n\n'
  printf '  %-4s %-14s %s\n' "#" "verdict" "message"
  for id in C1 C2 C3 C4 C5 C6 C7 C8 C9 C10 C11 C12 C13 C14 C15 C16 C17; do
    st=$(saved_status "$id")
    if [ -z "$st" ]; then
      printf '  %-4s %-14s %s\n' "$id" "$(color 90 'non joué')" "-"
      continue
    fi
    n_joue=$((n_joue + 1))
    case $st in
      OK)    n_ok=$((n_ok + 1)) ;;
      ECHEC) n_echec=$((n_echec + 1)); [ -n "$premier" ] || premier=$id ;;
      AVOIR) n_avoir=$((n_avoir + 1)) ;;
    esac
    printf '  %-4s %-14s %s\n' "$id" "$(status_label "$st")" \
      "$(awk -F'\t' -v id="$id" '$1==id { sub(/^[^\t]*\t[^\t]*\t[^\t]*\t/, ""); m=$0 } END { print m }' "$WORKDIR/resultats.tsv")"
  done
  printf '\n  joués : %s/17   OK : %s   ÉCHEC : %s   À VOIR : %s\n' \
    "$n_joue" "$n_ok" "$n_echec" "$n_avoir"
  [ -f "$WORKDIR/resultats.tsv" ] && printf '  détail : %s\n' "$WORKDIR/resultats.tsv"
  if [ "$n_echec" -gt 0 ]; then
    printf '\n  Premier point bloquant : %s — voir §6 de docs/installateur.md.\n' "$premier"
    return 1
  fi
  printf '\n  Aucun point en échec.\n'
  return 0
}

# =============================================================================
main() {
  parse_args "$@"
  mkdir -p "$WORKDIR"
  case $PHASE in
    p0)    phase_p0 ;;
    p1)    phase_p1 ;;
    p2)    phase_p2 ;;
    p3)    phase_p3 ;;
    p4)    phase_p4 ;;
    p5)    phase_p5 ;;
    p6)    phase_p6 ;;
    p7)    phase_p7 ;;
    recap) phase_recap; exit $? ;;
  esac
  if [ "$PHASE" != "recap" ]; then
    printf '\n  → verdicts enregistrés dans %s ; `--phase recap` pour le tableau.\n' "$WORKDIR/resultats.tsv"
  fi
}

main "$@"
