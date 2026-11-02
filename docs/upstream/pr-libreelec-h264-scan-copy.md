# Proposer à LibreELEC la libération de `h264->scan_copy`

Dossier de la contribution amont du correctif de fuite mémoire du décodeur
H.264 stateless (`meson-amvdec`). État : **à envoyer**. Décision de forme
ouverte (voir « Deux formes »).

## Le défaut

`codec_h264_stop()` libère tous les tampons cohérents du codec — `ext_fw`,
`workspace`, `sei`, `aux`, `lmem`, `colocate[]` — **sauf `h264->scan_copy`**,
alloué par `meson_amvdec_codec_h264_scan_copy()` :

```c
h264->scan_copy = kvmalloc(cap, GFP_KERNEL);   /* cap = vb2_plane_size(OUTPUT) */
```

`cap` est la taille du plan OUTPUT, soit 4 Mio en 1080p. Juste après le
rappel, le noyau libère les données privées du codec (`kfree(sess->priv)`
dans `vdec_stop_streaming`) : le pointeur est perdu et le tampon jamais rendu.

## La preuve (N5, S905L/GXL, 2026-11-02)

- **+4 088 ko de `Slab` et de `SUnreclaim` par session** de décodage matériel,
  reproductible sur 25 sessions ; le décodage logiciel ne fuit pas (+68 ko
  sur 13 min).
- Aucun cache dans `/proc/slabinfo` (pages de slab plates), `VmallocUsed` et
  `PageTables` plats, aucune imputation à la cgroup de Kodi, rien n'est rendu
  par l'arrêt de Kodi ni le déchargement du module.
- Sonde `__kvmalloc_node_noprof` filtrée sur `size > 4 000 000` : **une**
  allocation de 4 194 304 octets par session, et une seule.
- `kvmalloc()` sert 4 Mio via `kmalloc_order()`, qui compte les pages en
  `NR_SLAB_UNRECLAIMABLE` sans les rattacher à un cache — d'où l'écart entre
  `meminfo Slab` et la somme de `/proc/slabinfo`.
- Après correctif, trois sessions à chaud : **+16 ko** (contre +12 432 ko
  avant), et `meson-amvdec.ko` change de hash.

## La correction

Cinq lignes dans `codec_h264_stop()`, avant le retour :

```c
	/* The core frees the private data right after this callback. */
	kvfree(h264->scan_copy);
	h264->scan_copy = NULL;
	h264->scan_copy_size = 0;
```

`kvfree(NULL)` est sûr (sessions partiellement initialisées) et la remise à
zéro rend le rappel idempotent. Le patch est `amlogic-0129` dans
`nixelec-meson64` et dans `nixbian` (série `meson64-vdec-7.0`).

## Cible

- dépôt : `LibreELEC/LibreELEC.tv`
- répertoire : `projects/Amlogic/patches/linux/`
- commit de référence de notre sous-ensemble : `96d9f0fb` (2026-10-24),
  210 fichiers, `amlogic-0119` à `0128` pour la pile VPU
- auteurs de la série : Gus Bourg, Christian Hewitt ; les patchs portent
  `Assisted-by: Claude`

## Deux formes

1. **Amender `amlogic-0121`** (celui qui introduit `codec_h264.c`). C'est la
   forme propre pour une pile de patchs appliquée en bloc : pas de cicatrice
   « correction d'un patch qu'on vient d'ajouter ». Coût : régénérer 0121 et
   vérifier que 0122–0128 s'appliquent toujours dessus.
2. **Un patch séparé**, après leur dernier numéro. Attention : leur
   `amlogic-0129` **existe déjà** (ASoC `meson-card-expose-internal-PCM-controls`),
   donc le nôtre serait `0130`, et notre copie locale doit être renommée pour
   ne pas entretenir la confusion.

Recommandation : amender 0121 si la PR est acceptée en l'état ; sinon 0130.

## Ce que doit contenir le commit

- message au format noyau, avec la mesure : « 4 MiB per playback session on a
  GXL box, charged to `NR_SLAB_UNRECLAIMABLE` through `kmalloc_order()` » ;
- `Signed-off-by:` (DCO LibreELEC) ;
- `Assisted-by: Claude` si l'on suit la convention de la série ;
- un `Fixes:`-like explicite (renvoi à 0121/0122 dans le message) ;
- l'accord de l'auteur du fichier pour l'amendement (0121 est signé Gus Bourg).

## Checklist avant envoi

- [ ] appliquer le hunk sur **leur** empilement (notre `0119` est modifié
      localement : hunk `MAINTAINERS` retiré — sans effet ici, mais à vérifier) ;
- [ ] vérifier que `0122`–`0128` s'appliquent encore après l'amendement de 0121 ;
- [ ] renommer notre copie locale (`amlogic-0129` → autre) et corriger le
      README de la série qui annonce « 0118 à 0128 + correctif local » ;
- [ ] joindre la mesure à chaud (3 sessions) et le hash du module avant/après ;
- [ ] dire clairement que le défaut est indépendant de nixbian (série interne).

## Hors périmètre de la PR

- `series.conf` de `nixbian` : mécanisme interne de notre build, sans objet
  pour LibreELEC.
- La réduction du coût de zapping (~7 s), qui se joue dans l'addon Orange et
  non dans le noyau.
