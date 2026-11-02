# N5 — fuite mémoire du décodeur H.264 (2026-11-02)

## Symptôme

Chaque session de décodage matériel laisse ~4 Mio de mémoire noyau non
récupérée. `Slab` et `SUnreclaim` montent, `MemFree` baisse, et rien ne
redescend : ni l'arrêt de Kodi, ni le déchargement de `meson_amvdec`, ni le
redémarrage du service.

Mesures sur 3 sessions de 20 s (mire 1080p, `videoplayer.useprimedecoder=true`) :

| compteur | avant | après | delta |
|---|---|---|---|
| Slab | 333 396 ko | 345 680 ko | **+12 284 ko** |
| SUnreclaim | 269 284 ko | 281 564 ko | +12 284 ko |
| VmallocUsed | 17 860 ko | 17 924 ko | +64 ko |
| PageTables | 5 224 ko | 5 284 ko | +60 ko |
| CmaFree | 211 504 ko | 211 220 ko | −284 ko |

Le décodage logiciel (`useprimedecoder=false`) ne fuit pas (+68 ko sur 13 min).
`ffmpeg -hwaccel drm` sans Kodi reproduit la fuite : ce n'est ni Kodi ni les
greffons.

## Ce que la mesure exclut

- **Aucun cache SLUB ne grossit** : les pages de `/proc/slabinfo` restent
  plates (+2 pages en tout), alors que `Slab` gagne 8 Mio par passage.
- **Ce n'est pas du vmalloc** : `VmallocUsed` est plat, et `vmap`/`vunmap`
  s'équilibrent (49/49 par session).
- **Ce n'est pas imputé au processus** : la cgroup `kodi-gbm` ne voit rien
  (`slab` 39 ko), arrêter Kodi rend 228 ko, décharger le module 332 ko.
- **Les allocations DMA s'équilibrent** : `dma_alloc_attrs` = `dma_free_attrs`
  en nombre, en taille (11 × 4 Mio, 11 × 2 Mio, 11 × 1 Mio, 11 × 783 360,
  1 × 8 192, 1 × 4 096 de part et d'autre) et en device.
- `dma_common_free_remap` n'est jamais appelé, mais `vunmap` l'est : le noyau
  défait le mapping par un autre chemin. Ce compteur seul n'est pas un indice.

## Cause

`codec_h264_stop()` libère tous les tampons cohérents du codec, mais pas
`h264->scan_copy`, alloué par `meson_amvdec_codec_h264_scan_copy()` :

```c
h264->scan_copy = kvmalloc(cap, GFP_KERNEL);   /* cap = vb2_plane_size(OUTPUT) */
```

`cap` vaut la taille du plan OUTPUT, soit 4 Mio en 1080p. Le noyau libère
ensuite les données privées du codec (`kfree(sess->priv)` dans
`vdec_stop_streaming`), donc le pointeur est perdu et le tampon jamais rendu.

Preuve directe, sonde sur `__kvmalloc_node_noprof` pendant une session :
une allocation de **4 194 304 octets**, et une seule.

L'absence de cache dans `/proc/slabinfo` s'explique : `kvmalloc()` de 4 Mio
passe par `kmalloc_order()`, qui compte les pages en `NR_SLAB_UNRECLAIMABLE`
sans les rattacher à un cache. C'est exactement la signature relevée
(Slab = SUnreclaim qui montent, vmalloc et page tables plats, aucune
imputation cgroup).

## Correctif

`amlogic-0129-media-amlogic-amvdec-h264-free-scan-copy.patch` : libère
`scan_copy` dans `codec_h264_stop()`, avant que le noyau ne libère les
données privées. `kvfree(NULL)` étant sûr, les sessions partiellement
initialisées sont couvertes, et la remise à zéro évite une double
libération si le rappel est invoqué deux fois.

## Piège de livraison (mesuré)

La série **appliquée** n'est pas celle de ce dépôt : le noyau de `nixbian`
prend `metadata/nix/patches/kernel/meson64-vdec-7.0/series.conf` de la
branche `feat/meson64-vdec-7.0`. Ajouter le fichier ici ne change rien au
build : la dérivation du noyau, `Image` et `meson-amvdec.ko` restaient
**identiques** (même hash de module), et la fuite persistait après
déploiement. Il faut ajouter le patch à `series.conf` dans `nixbian`, puis
remonter les locks (`nixelec-meson64`, puis HavenOS).

Vérification qui tranche : comparer le hash de `meson-amvdec.ko` entre
l'ancienne génération et la nouvelle. Identique = correctif absent du build,
inutile de redémarrer.

## Résultat (N5, après déploiement)

Trois sessions à chaud, même sonde :

| compteur | avant | après | delta |
|---|---|---|---|
| Slab | 72 208 ko | 72 224 ko | **+16 ko** |
| SUnreclaim | 46 400 ko | 46 416 ko | +16 ko |

Contre +12 432 ko pour les trois mêmes sessions avant correctif. La mesure
précédente, juste après le démarrage, donne +1 056 ko sur trois sessions
(mise en route de Kodi), et non plus ~4 100 ko par session.

Le noyau `Image` est inchangé (le correctif ne touche qu'un module) : c'est
`meson-amvdec.ko` (`8a4aa00d…` contre `aaa628dd…`) qui porte la correction.

