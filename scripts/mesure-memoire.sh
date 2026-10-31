#!/usr/bin/env bash
# =============================================================================
# mesure-memoire.sh — les trois états de `docs/empreinte-memoire.md`, rejouables.
#
# Mesure, depuis le poste, la mémoire du kiosque sur une carte joignable en SSH :
#   sans-kodi   aucun kodi.bin (l'unité est arrêtée), attendu 10 Mo de CMA
#   inactif     kiosque démarré depuis >= 60 s, interface seule
#   lecture     kiosque en lecture, échantillonné sur --duree secondes
#
# Pièges déjà payés, encodés ici :
#   - `Pss` lu trop tôt est faux (233 Mo à 18 s contre 296 Mo à chaud) : on
#     attend 60 s avant l'état inactif, et on refuse de mesurer avant.
#   - `MainPID` n'est pas `kodi.bin` (c'est le wrapper `.kodi-wrapped`) : on
#     sélectionne le processus par nom exact, jamais par PID d'unité.
#   - `CmaTotal` est hors `MemTotal` : les deux sont lus, jamais déduits l'un de
#     l'autre.
#   - arrêter le kiosque plus de ~10 s casse le sink audio (item 49) : l'état
#     `sans-kodi` répare explicitement la pile audio au redémarrage.
#
# Aucune écriture sur la carte : uniquement `systemctl`, `cat` et `pkill` sur un
# processus déjà arrêté. Le redémarrage du kiosque est fait par systemd.
# =============================================================================
set -euo pipefail

HOST=""
ETAT="tous"
DUREE=30
ATTENTE=60
SORTIE=""

usage() {
  cat <<'EOF'
usage : scripts/mesure-memoire.sh --host root@<ip> [options]

  --host <hôte>     carte à mesurer (requis)
  --etat <état>     sans-kodi | inactif | lecture | tous   (défaut : tous)
  --duree <s>       durée d'échantillonnage de l'état lecture (défaut : 30)
  --attente <s>     chauffe avant l'état inactif (défaut : 60, plancher : 60)
  --sortie <fichier> CSV appendé (sinon stdout seulement)
  -h, --help        cette aide

Sortie : une ligne CSV par état, entête incluse au premier passage.
Colonnes : etat,date,memtotal_kb,memavailable_kb,cmatotal_kb,cmafree_kb,
           slab_kb,kodi_pss_kb,kodi_pss_anon_kb,kodi_pss_file_kb,kodi_nb_proc,
           vdec_wxh (résolution décodée, vide hors lecture)
EOF
}

die() { printf 'mesure-memoire : %s\n' "$*" >&2; exit 1; }
note() { printf '→ %s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
  case $1 in
    --host) HOST=${2:?--host attend une valeur}; shift 2 ;;
    --etat) ETAT=${2:?--etat attend une valeur}; shift 2 ;;
    --duree) DUREE=${2:?--duree attend une valeur}; shift 2 ;;
    --attente) ATTENTE=${2:?--attente attend une valeur}; shift 2 ;;
    --sortie) SORTIE=${2:?--sortie attend une valeur}; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) die "option inconnue : $1" ;;
  esac
done

[ -n "$HOST" ] || { usage >&2; exit 2; }
case $ETAT in sans-kodi | inactif | lecture | tous) ;; *) die "--etat invalide : $ETAT" ;; esac
[ "$ATTENTE" -ge 60 ] || ATTENTE=60

SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST")

# Lecture d'un état : une seule session SSH, tout est calculé sur la carte.
releve() {
  local etat=$1
  "${SSH[@]}" bash -s -- "$etat" <<'EOS'
set -u
etat=$1

mem() { awk -v k="$1" '$1 == k":" {print $2}' /proc/meminfo; }

# Pss par processus, jamais par PID d'unité (MainPID = le wrapper).
pss=0
pss_anon=0
pss_file=0
nb=0
for p in $(pgrep -x kodi.bin || true); do
  [ -r "/proc/$p/smaps_rollup" ] || continue
  nb=$((nb + 1))
  pss=$((pss + $(awk '/^Pss:/ {print $2}' "/proc/$p/smaps_rollup")))
  pss_anon=$((pss_anon + $(awk '/^Pss_Anon:/ {print $2}' "/proc/$p/smaps_rollup")))
  pss_file=$((pss_file + $(awk '/^Pss_File:/ {print $2}' "/proc/$p/smaps_rollup")))
done

# Résolution réellement décodée, lue sur le périphérique de capture du VPU et
# non sur l'interface : deux mesures de `CmaFree` ne sont comparables que si la
# source a la même définition (les tampons suivent la source, pas l'affichage).
# Vide quand rien n'est décodé (le pilote peut répondre pendant la lecture).
vdec=$(v4l2-ctl -d /dev/video0 --get-fmt-video 2>/dev/null | awk -F: '/Width\/Height/ {gsub(/[ \t]/,"",$2); print $2}')

printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
  "$etat" \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  "$(mem MemTotal)" \
  "$(mem MemAvailable)" \
  "$(mem CmaTotal)" \
  "$(mem CmaFree)" \
  "$(mem Slab)" \
  "$pss" \
  "$pss_anon" \
  "$pss_file" \
  "$nb" \
  "${vdec:-}"
EOS
}

attendre_kodi() {
  local i
  for i in $(seq 1 40); do
    if "${SSH[@]}" 'pgrep -x kodi.bin >/dev/null'; then return 0; fi
    sleep 0.5
  done
  die "kodi.bin n'est pas revenu après 20 s"
}

arreter_kodi() {
  local i
  note "arrêt de kodi-gbm"
  "${SSH[@]}" 'systemctl stop kodi-gbm' || die "systemctl stop kodi-gbm a échoué"
  for i in $(seq 1 20); do
    "${SSH[@]}" 'pgrep -x kodi.bin >/dev/null' || return 0
    sleep 0.5
  done
  die "kodi.bin tourne encore 10 s après l'arrêt : ne pas mesurer dans cet état"
}

demarrer_kodi() {
  note "redémarrage de kodi-gbm"
  "${SSH[@]}" 'systemctl start kodi-gbm' || die "systemctl start kodi-gbm a échoué"
  attendre_kodi
  # Le trou d'arrêt a dépassé les ~10 s mesurés (item 49) : le sink HDMI a pu
  # disparaître derrière Kodi. On le vérifie et on répare si besoin.
  if ! "${SSH[@]}" 'runuser -u kodi -- env XDG_RUNTIME_DIR=/run/user/$(id -u kodi) wpctl inspect @DEFAULT_AUDIO_SINK@ 2>/dev/null | grep -q node.name'; then
    note "sink audio absent après le redémarrage : réparation de la pile audio"
    "${SSH[@]}" 'systemctl stop kodi-gbm; runuser -u kodi -- env XDG_RUNTIME_DIR=/run/user/$(id -u kodi) systemctl --user restart pipewire pipewire-pulse wireplumber; systemctl start kodi-gbm' \
      || die "réparation audio échouée : voir docs/cec-rechargement-sur.md §2.10"
    attendre_kodi
  fi
}

entete() {
  printf '%s\n' "etat,date,memtotal_kb,memavailable_kb,cmatotal_kb,cmafree_kb,slab_kb,kodi_pss_kb,kodi_pss_anon_kb,kodi_pss_file_kb,kodi_nb_proc,vdec_wxh"
}

emettre() {
  local ligne
  ligne=$(releve "$1")
  printf '%s\n' "$ligne"
  [ -n "$SORTIE" ] && printf '%s\n' "$ligne" >>"$SORTIE"
}

: >/dev/null
if [ -n "$SORTIE" ] && [ ! -s "$SORTIE" ]; then entete >>"$SORTIE"; fi

case $ETAT in
  sans-kodi)
    arreter_kodi
    emettre sans-kodi
    demarrer_kodi
    ;;
  inactif)
    note "attente de ${ATTENTE}s (Pss faux avant 60 s)"
    sleep "$ATTENTE"
    emettre inactif
    ;;
  lecture)
    note "échantillonnage de ${DUREE}s : lancer la lecture maintenant"
    emettre lecture
    sleep "$DUREE"
    emettre lecture
    ;;
  tous)
    arreter_kodi
    emettre sans-kodi
    demarrer_kodi
    note "attente de ${ATTENTE}s (Pss faux avant 60 s)"
    sleep "$ATTENTE"
    emettre inactif
    note "échantillonnage de ${DUREE}s : lancer la lecture maintenant"
    emettre lecture
    sleep "$DUREE"
    emettre lecture
    ;;
esac
