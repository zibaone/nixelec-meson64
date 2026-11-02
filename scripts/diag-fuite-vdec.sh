#!/bin/sh
# Attribution de la fuite mémoire du décodeur matériel meson-amvdec.
#
# Contexte (mesuré le 2026-11-02 sur la N5) : chaque session de décodage
# matériel laisse ~4 Mio de mémoire noyau non récupérée (« Slab »/« SUnreclaim »
# qui montent). Le décodage logiciel ne fuit pas. `ffmpeg -hwaccel drm` seul
# reproduit la fuite : ce n'est ni Kodi ni les greffons.
#
# Ce script sonde, sans recompiler le noyau :
#   - dma_alloc_attrs / dma_free_attrs            : les tampons cohérents ;
#   - dma_common_contiguous_remap / free_remap   : le mapping vmalloc associé.
#
# Résultat de référence (3 sessions, Kodi) :
#   dma_alloc_attrs 147, dma_free_attrs 147,
#   dma_common_contiguous_remap 147, dma_common_free_remap 0
# et les piles montrent :
#   allocation : vb2_dc_alloc -> dma_alloc_attrs -> dma_common_contiguous_remap
#   libération : amvdec_1_stop -> dma_free_attrs
#
# ATTENTION : `dma_common_free_remap` à zéro ne prouve PAS un remap fuité.
# Une sonde sur `vmap`/`vunmap` donne 49/49 pour la même session : le noyau
# défait bien le mapping, par un autre chemin que `dma_common_free_remap`.
#
# Ce qui est établi :
#   - allocations et libérations s'équilibrent en nombre, en taille et en
#     device (alloc 49 / free 49 ; 11 x 4 Mio, 11 x 2 Mio, 11 x 1 Mio,
#     11 x 783360, 1 x 8192, 1 x 4096 de part et d'autre) ;
#   - les caches SLUB ne bougent pas (/proc/slabinfo : pages stables) ;
#   - VmallocUsed et PageTables sont plats ;
#   - arrêter Kodi (-228 ko) ou décharger meson_amvdec (-332 ko) ne rend rien ;
#   - la cgroup kodi-gbm ne voit rien non plus (slab 39 ko).
# Autrement dit : ~4 Mio par session partent en mémoire noyau non comptabilisée
# par les caches, dans le contexte du pilote.
#
# CAUSE TROUVÉE (sonde `__kvmalloc_node_noprof`) : une seule allocation
# kvmalloc de 4 194 304 octets par session, et `codec_h264_stop()` ne libère
# pas `h264->scan_copy` (le noyau libère ensuite `sess->priv`, le pointeur est
# perdu). kvmalloc sert 4 Mio via kmalloc_order(), donc les pages vont dans
# NR_SLAB_UNRECLAIMABLE sans cache visible : c'est exactement la signature
# mesurée. Correctif : amlogic-0129.


#
# Usage : diag-fuite-vdec.sh [sessions] [--pile]
#   --pile   attache un stacktrace aux sondes remap/free (verbeux).
#
# Prérequis : root sur la box, Kodi qui tourne (le décodeur garde /dev/video0
# ouvert, donc ffmpeg ne peut pas l'utiliser en parallèle), tracefs monté.
set -u

HOST=${HOST:-localhost}
SESSIONS=3
PILE=0
for arg in "$@"; do
    case "$arg" in
        --pile) PILE=1 ;;
        *[!0-9]*) echo "argument inconnu : $arg" >&2; exit 2 ;;
        *) SESSIONS=$arg ;;
    esac
done

T=/sys/kernel/tracing
MIRE=/nix/store/hskqa9kgr5w098wnmxv0659mffrxmlgn-mire-1080p.mp4
PW=$(cat /run/havenos/kodi-webserver-password)

rpc() {
    curl -s -m 5 -u "kodi:$PW" -H 'Content-Type: application/json' -d "$1" \
        http://127.0.0.1:8080/jsonrpc >/dev/null
}
mem() { grep -E '^(Slab|SUnreclaim|MemFree|CmaFree):' /proc/meminfo | tr '\n' ' '; echo; }

[ -d "$T" ] || { echo "tracefs absent" >&2; exit 1; }
cd "$T" || exit 1

echo 0 > tracing_on
echo 0 > events/kprobes/enable 2>/dev/null

grep -q dbg_alloc kprobe_events 2>/dev/null || {
    echo 'p:dbg_alloc dma_alloc_attrs' >> kprobe_events
    echo 'p:dbg_free dma_free_attrs' >> kprobe_events
    echo 'p:dbg_remap dma_common_contiguous_remap' >> kprobe_events
    echo 'p:dbg_unremap dma_common_free_remap' >> kprobe_events
}

if [ "$PILE" = 1 ]; then
    echo 'stacktrace' > events/kprobes/dbg_remap/trigger
    echo 'stacktrace' > events/kprobes/dbg_free/trigger
fi

echo > trace
echo 16384 > buffer_size_kb
echo 1 > events/kprobes/enable
echo 1 > tracing_on

echo "avant : $(mem)"
i=1
while [ "$i" -le "$SESSIONS" ]; do
    rpc "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"Player.Open\",\"params\":{\"item\":{\"file\":\"$MIRE\"}}}"
    sleep 20
    rpc '{"jsonrpc":"2.0","id":2,"method":"Player.Stop","params":{"playerid":1}}'
    sleep 4
    i=$((i + 1))
done
sleep 5
echo "apres : $(mem)"

echo 0 > tracing_on
echo 0 > events/kprobes/enable

for e in dbg_alloc dbg_free dbg_remap dbg_unremap; do
    printf '%-12s %s\n' "$e" "$(grep -c "$e:" trace)"
done

if [ "$PILE" = 1 ]; then
    echo '--- pile allocation (dbg_remap) ---'
    grep -A14 'dbg_remap:' trace | head -18
    echo '--- pile liberation (dbg_free) ---'
    grep -A16 'dbg_free:' trace | head -20
fi
