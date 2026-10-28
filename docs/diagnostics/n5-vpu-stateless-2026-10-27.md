# N5 — VPU stateless meson-amvdec, mesures du 2026-10-27

> Relevé UART sur l'image `magicsee-n5-sd-image` (noyau 7.0.14, patchs
> `meson64-vdec-7.0`). **`H264_SLICE` est mesuré présent** via `VIDIOC_ENUM_FMT`.
> **Décodage matériel H.264 1080p mesuré** le 2026-10-28 après le patch `0002` :
> `utime` 4,98–5,01 s contre 10,87–10,97 s en logiciel, avec expérience de
> contrôle (microcode retiré) qui fait retomber le temps logiciel.
> **HEVC décode depuis le correctif `0004`** (bit-exact, CPU ÷ 3,0) et **VP9
> depuis `0003`** (bit-exact, CPU ÷ 1,6). **MPEG-2** décode mais régresse — les
> quatre sont mesurés, voir « Autres codecs ».

## Méthode

L'image de bring-up est volontairement minimale : ni `v4l2-ctl`, ni `ffmpeg`, ni
Nix, pas de réseau. Plutôt que de reconstruire une image pour l'occasion, un
sondeur V4L2 de 80 Kio a été cross-compilé en statique
(`pkgsCross.aarch64-multiplatform.pkgsStatic`, musl), poussé sur la console en
base64 par blocs de 448 caractères et vérifié par empreinte :

```text
sha256sum /tmp/v4l2probe
deffd09b14b06c0f02743f8c05510c08bfbbc03021512ee805a60196c299f3ba  /tmp/v4l2probe
```

Il fait `VIDIOC_QUERYCAP` puis `VIDIOC_ENUM_FMT` sur la file `OUTPUT` (codé) et
la file `CAPTURE` (brut), soit l'équivalent de `v4l2-ctl --list-formats-out`
et `--list-formats-in`. Source : `/tmp/opencode/n5-v4l2probe.c`.

> Attention au débit : à 115200 8N1 une ligne de 530 octets met ~46 ms sur le
> fil. Envoyer plus vite que le débit réel tronque silencieusement les lignes
> (et casse l'état de quoting du shell). Le pousseur cale donc son délai sur
> `longueur / 11000`.

## Relevé

```text
dev=/dev/video0
driver=meson-amvdec card=Amlogic Video Decoder bus=platform:meson-amvdec
caps=0x84204000 device_caps=0x04204000
m2m_mplane=1 streaming=1
OUTPUT (coded):
  S264 H.264 Parsed Slice Data flags=0x1
  S265 HEVC Parsed Slice Data flags=0x1
  MG2S MPEG-2 Parsed Slice Data flags=0x1
  VP9F VP9 Frame flags=0x1
CAPTURE (raw):
  NM12 Y/UV 4:2:0 (N-C) flags=0x0
```

Lecture :

| Élément | Valeur | Sens |
|---|---|---|
| `device_caps` | `0x04204000` | `VIDEO_M2M_MPLANE` + `STREAMING` |
| `S264` | `V4L2_PIX_FMT_H264_SLICE` | décodage **stateless** par tranches parsées |
| `S265` | `V4L2_PIX_FMT_HEVC_SLICE` | idem HEVC (annoncé) |
| `MG2S` | `V4L2_PIX_FMT_MPEG2_SLICE` | idem MPEG-2 (annoncé) |
| `VP9F` | `V4L2_PIX_FMT_VP9_FRAME` | VP9 (annoncé) |
| `NM12` | `V4L2_PIX_FMT_NV12M` | unique format de sortie brut |
| `flags=0x1` | `V4L2_FMT_FLAG_COMPRESSED` | format codé côté `OUTPUT` |

C'est bien le chemin **stateless** : le driver attend des tranches parsées par
l'espace utilisateur, pas un flux élémentaire. À comparer au relevé LibreELEC
du 2026-10-26 (`meson_vdec` stateful : `H264`, `HEVC`, `VP90` en sortie, **pas**
de `H264_SLICE`) — le remplacement stateful → stateless est donc effectif.

## État de la pile

```text
# cat /sys/class/video4linux/video0/name
meson-video-decoder
# ls /sys/bus/platform/drivers/meson-amvdec/
bind  c8820000.video-codec  module  uevent  unbind
```

```text
meson_amvdec          233472  0
v4l2_h264              16384  1 meson_amvdec
v4l2_mem2mem           28672  1 meson_amvdec
videobuf2_dma_contig   20480  1 meson_amvdec
videobuf2_v4l2         20480  2 meson_amvdec,v4l2_mem2mem
videodev              253952  3 meson_amvdec,videobuf2_v4l2,v4l2_mem2mem
mc                     61440  5 videodev,meson_amvdec,…
```

Un seul nœud : `/dev/video0`. Le driver `meson-amvdec` est bindé sur
`c8820000.video-codec`, et `v4l2_h264` (l'aide au parsing H.264) est chargé et
référencé par `meson_amvdec`.

## Ce qui n'est pas prouvé

- **Aucun décodage n'a tourné.** `H264_SLICE` est une capacité annoncée par
  `ENUM_FMT`, pas une mesure de décodage. Il n'y a eu ni `h264_v4l2request`, ni
  flux 1080p, ni mesure de débit ou de charge CPU.
- **HEVC et VP9 ne sont pas validés.** Les formats `S265` et `VP9F` sont
  annoncés par le driver ; rien ne dit qu'un décodage aboutit sur ce S905L.
  Ne pas les promettre avant une mesure.
- **MPEG-2** idem (`MG2S` annoncé seulement).
- **Un seul format de capture** (`NV12M`) : toute conversion (I420, P010, 10
  bits) se fera côté utilisateur.

## Image de qualification (construite le 2026-10-27)

```sh
nix build --override-input nixbian path:../nixbian-vdec \
  .#packages.aarch64-linux.magicsee-n5-decode-image --out-link result-decode
```

- **2,43 Gio brute / 453 Mio compressée** (racine 1,9 Gio) → **carte ≥ 4 Go**.
  L'image minimale faisait 1,46 Gio : une carte de 2 Go ne suffit plus.
- Ajouts : `v4l-utils` (`v4l2-ctl`), `ffmpeg` 6.1.6 patché v4l2-request
  (fermeture 267 Mio), et `/etc/n5/samples/sample-1080p.h264`
  (2 984 711 octets, H.264 **High@4.1**, 1920×1080, yuv420p, 6 s).
- L'échantillon est encodé **à la construction** par le ffmpeg x86_64 de
  l'hôte (`-c:v libx264`), donc rien de binaire n'est commité : la cible n'a
  aucun encodeur.
- `/etc/n5/decode-test.sh` compare décodage logiciel et `-hwaccel drm` avec
  `-benchmark` (utime/stime). C'est le seul critère honnête : un décodage
  **logiciel réussit aussi**, donc « ffmpeg sort sans erreur » ne prouve rien.

## Piège d'invocation : `-hwaccel drm`, pas `-hwaccel v4l2request`

Mesuré sur le binaire aarch64, celui de l'image :

```text
$ ffmpeg -hwaccel v4l2request …
Unrecognized hwaccel: v4l2request.
Supported hwaccels: vdpau cuda vaapi drm opencl vulkan
$ ffmpeg -hwaccel h264_v4l2request …
Unrecognized hwaccel: h264_v4l2request.
$ ffmpeg -hwaccel drm …
[h264] v4l2_request_probe_media_device: get media device info failed (25)
[h264] Failed setup for format drm_prime: hwaccel initialisation returned error.
```

Le patch enregistre
`HW_CONFIG_HWACCEL(1, 0, 0, DRM_PRIME, DRM, ff_h264_v4l2request_hwaccel)`, et
le nom du hwaccel est `h264_v4l2request`. Mais **ffmpeg ne le résout pas par
son nom** : la sélection passe par la hw config `DRM_PRIME` avec
`device_type == DRM`. D'où `-hwaccel drm`. L'échec ci-dessus est normal sur une
machine sans V4L2 : le code v4l2request est bien atteint.

`-hwaccels` ne peut pas servir de gate (pas d'`AVHWDEVICE_TYPE_V4L2REQUEST` en
FFmpeg 6.1). Le bon gate est le test C du dépôt, qui passe pour l'aarch64 :

```text
OK h264: pix_fmt=drm_prime methods=HW_DEVICE_CTX device_type=drm
OK hevc: pix_fmt=drm_prime methods=HW_DEVICE_CTX device_type=drm
```

Et le code est bien compilé : `ff_h264_v4l2request_hwaccel` et
`ff_hevc_v4l2request_hwaccel` sont présents dans `libavcodec.so.60`
(`--enable-v4l2-request` figure aussi dans `-buildconf`).

## Ce que la sonde attend du noyau

`ff_v4l2_request_init()` énumère **udev sur le sous-système `media`**
(`udev_enumerate_add_match_subsystem(enumerate, "media")`) et sonde chaque
device ; `-hwaccel_device` n'intervient pas dans ce choix. Sur la N5 :

```text
udevadm info -q property -n /dev/media0
  DEVPATH=/devices/platform/soc/c8820000.video-codec/media0
  DEVNAME=/dev/media0
  SUBSYSTEM=media
/sys/bus/media/devices/ → media0
```

Piège : **`/sys/class/media` n'existe pas** sur ce noyau — le device est
enregistré sur le *bus* `media`, pas sur une classe. L'énumération udev
fonctionne quand même (elle couvre `/sys/bus`). Ne pas conclure « pas de media
device » depuis `ls /sys/class/media`.

## Mesure du 2026-10-28 : échec matériel, repli logiciel

Image `magicsee-n5-decode-image` sur carte 32 Go, noyau 7.0.14, UART.

```text
# contrôle logiciel (3 passes)
bench: utime=11.173s stime=0.266s
bench: utime=11.175s stime=0.286s
bench: utime=11.176s stime=0.314s

# -hwaccel drm (3 passes)
[h264] Failed setup for format drm_prime: hwaccel initialisation returned error.
bench: utime=11.202s stime=0.285s
bench: utime=11.151s stime=0.244s
bench: utime=11.184s stime=0.268s
```

Les deux chemins consomment **le même CPU** : ffmpeg retombe silencieusement en
logiciel. Le VPU **n'a pas travaillé**. Un `ffmpeg` qui sort en code 0 ici ne
prouve rien — c'est exactement le piège que le script de mesure devait révéler.

Trace `-loglevel debug` :

```text
ff_v4l2_request_init: ctx=… hw_device_ctx=… hw_frames_ctx=(nil)
v4l2_request_probe_media_device: path=/dev/media0 driver=meson-amvdec
v4l2_request_probe_video_device: path=/dev/video0 capabilities=69222400
v4l2_request_probe_video_device: select capture format failed
No V4L2 media device found for S264
```

(`capabilities` est un `%u` : 69222400 = `0x04204000`, soit `M2M_MPLANE` +
`STREAMING`. Le media device, le nœud vidéo et le format de sortie `S264` sont
donc tous acceptés ; seul le format de **capture** échoue.)

## Cause racine : `NV12M` côté driver, `NV12` côté ffmpeg

1. `meson-amvdec` n'expose qu'un format de capture : **`NV12M`**
   (multi-plan, fourcc `NM12`). `v4l2-ctl -d /dev/video0 --list-formats`
   (mono-plan) ne renvoie rien.
2. La table d'ffmpeg `v4l2_request_capture_pixelformats[]` du jeu LibreELEC
   contient `V4L2_PIX_FMT_NV12`, `SUNXI_TILED_NV12`, `NV15`, `NV16`, `NV20`,
   `P010` et des formats AFBC — **pas `V4L2_PIX_FMT_NV12M`**.
3. `v4l2_request_select_capture_format()` énumère les formats du driver et les
   compare à cette table : aucun ne correspond → retour `-1` →
   « No V4L2 media device found » → échec d'initialisation → repli logiciel.

C'est un **désaccord de format entre le driver et l'espace utilisateur**, pas un
problème de noyau, de DTB ou de droits. Le patch v4l2-request a été écrit pour
`cedrus` (sunxi), qui expose `NV12` mono-plan.

Conséquence à ne pas oublier : le chemin Kodi passe par le **même**
`ff_v4l2_request_init()`, donc la même impasse l'attend sur cette boîte tant que
le format n'est pas aligné (non mesuré côté Kodi, mais c'est le même code).

## Pistes de correction — arbitrage du 2026-10-28

### Piste 1 (driver mono-plan) : écartée, infaisable

Le jeu de patchs nixbian est strictement multi-plan :

- `device_caps = V4L2_CAP_VIDEO_M2M_MPLANE | V4L2_CAP_STREAMING`
  (`amlogic-0119`, l.1389) ;
- tous les ioctls sont `_mplane` : `vidioc_g_fmt_vid_cap_mplane`,
  `vidioc_try_fmt_vid_cap_mplane`… ;
- `pixfmts_cap = { V4L2_PIX_FMT_NV12M, 0 }` dans chaque descripteur
  (`amlogic-0121`).

Un device V4L2 est **soit** mono-plan **soit** multi-plan, jamais les deux.
« Exposer NV12 » signifierait réécrire le driver en mono-plan, ce qui casserait
l'usage des formats `S264` par la Request API. Piste abandonnée.

### Piste 2 (ffmpeg multi-plan) : implémentée, mesurée

Patch `pkgs/ffmpeg-v4l2request/patches/0002-v4l2-request-nv12m-capture.patch`
dans `nix-v4l2-request`, additif — les formats mono-plan (NV12, sunxi tiled,
P010, AFBC) sont inchangés :

| Endroit | Avant | Après |
|---|---|---|
| `v4l2_request_capture_pixelformats[]` | pas d'entrée NV12M | `NV12M → DRM_FORMAT_NV12 / LINEAR` |
| `v4l2_request_set_format()` | `num_planes = 1` | `2` si `NV12M` |
| `queue`/`dequeue_buffer()` | `planes[1]`, `length = 1` | `planes[2]`, `length = nb_planes` |
| `buffer_alloc()` | un `VIDIOC_EXPBUF` | un par plan (`fd`, `fd_plane1`) |
| `set_drm_descriptor()` | 1 objet, UV à `pitch * height` | 2 objets, un plan chacun |

Le dernier point est le vrai travail : le code supposait **un dmabuf unique**
contenant Y puis UV, ce qui est faux en NV12M (Y et UV sont deux dmabufs
distincts, chacun exporté séparément). Le descripteur décrit donc deux objets ;
conséquence à ne pas oublier : un consommateur qui construit un framebuffer DRM
unique (`drmModeAddFB2`) ne gère que la disposition à un seul objet. Sans effet
pour `-f null`, à revoir avant de brancher Kodi.

Mesuré côté driver (`v4l2-ctl --get-fmt-video`) : `Number of planes: 2`,
plane 0 `bytesperline = 1280` — cohérent avec le descripteur, pas de valeur de
repli nécessaire.

`patchPhase` passe dans le build Nix (`patching file libavcodec/v4l2_request.c`)
et `configure` tourne avec `--enable-v4l2-request`. **Aucun décodage n'a encore
été exécuté avec ce patch.**

## Prérequis oubliés, trouvés en creusant : deux blocages matériels

### 1. Les microcodes VPU ne sont pas dans l'image

`amvdec_1_load_firmware()` appelle `request_firmware()` sur
`fmt_out->firmware_path`, soit `meson/vdec/gxl_h264_multi.bin` pour H.264 sur
GXL. Ces fichiers **ne sont pas dans linux-firmware** : ils viennent de
`LibreELEC/meson-firmware` (branche `stateless`).

Or l'image ne livrait que `ath10k` et `qca`, `minimal.nix` forçant
`hardware.firmware`. Même avec un ffmpeg correct, le VPU n'aurait pas démarré.

Corrigé par un paquet dédié dans `decode-tools.nix`, épinglé sur
`662b843714ac18e92b19887fadc8d8b3d94fc814`. Licence Amlogic : redistribution
autorisée pour les appareils à puce Amlogic, mais **pas dans l'arbre du noyau**
ni sous GPL — d'où un paquet séparé, avec le `LICENSE` amont recopié.

### 2. Le noyau ne décompresse aucun firmware

```text
$ zcat /proc/config.gz | grep FW_LOADER
CONFIG_FW_LOADER_USER_HELPER=y
# CONFIG_FW_LOADER_COMPRESS is not set
```

Or nixpkgs livre l'arbre firmware en `.zst` par défaut
(`hardware.firmwareCompression = "zstd"`) : **aucun** firmware n'était
chargeable — `ath10k` compris, ce qui explique les messages WiFi du bring-up.

Corrigé par `hardware.firmwareCompression = lib.mkForce "none"`. Vérifié après
reconstruction de l'arbre : `lib/firmware/meson/vdec/gxl_h264_multi.bin` et
`lib/firmware/ath10k/QCA9377/hw1.0/board-2.bin` sortent **non compressés**.

## Mesure après correctifs : décodage matériel H.264 1080p

Conditions : image `magicsee-n5-decode` déjà en place, donc **sans reflash** — la
nouvelle `libavcodec.so.60` (patch `0002`) a été poussée sur la cible et chargée
par `LD_LIBRARY_PATH`, le microcode par
`/sys/module/firmware_class/parameters/path`. Échantillon inchangé
(1920×1080, High@4.1, 6 s, 180 images).

```text
# contrôle logiciel (3 passes)
bench: utime=10.868s stime=0.293s rtime=3.227s
bench: utime=10.904s stime=0.233s rtime=3.172s
bench: utime=10.968s stime=0.259s rtime=3.128s

# -hwaccel drm (3 passes)
bench: utime=5.010s stime=0.337s rtime=5.333s
bench: utime=4.978s stime=0.363s rtime=5.350s
bench: utime=4.981s stime=0.380s rtime=5.342s
```

| | `utime` | `rtime` | `speed` |
|---|---|---|---|
| logiciel | 10,87–10,97 s | 3,13–3,23 s | ~1,9× temps réel |
| matériel | **4,98–5,01 s** | 5,33–5,35 s | 1,12× temps réel |

Le CPU consommé est **divisé par 2,2**. En revanche le temps *mural* est
**moins bon** qu'en logiciel : le décodage logiciel sature 3–4 cœurs
(10,9 s de CPU en 3,2 s), tandis que le chemin matériel est essentiellement
mono-thread et attend le VPU à chaque image (5,0 s de CPU en 5,3 s). Le VPU
décharge donc le CPU ; il n'accélère pas ce cas d'usage à 1080p.

### Expérience de contrôle : sans microcode, retour au logiciel

Le doute à lever était « est-ce vraiment le VPU, ou un chemin logiciel qui va
plus vite ? ». Le répertoire de firmware est retiré, même commande :

```text
meson-amvdec c8820000.video-codec: Direct firmware load for
  meson/vdec/gxl_h264_multi.bin failed with error -2
[h264] Using V4L2 media device /dev/media0 (meson-amvdec) for S264
[h264] Failed setup for format drm_prime: hwaccel initialisation returned error.
bench: utime=10.956s stime=0.409s rtime=3.272s
```

Le hwaccel échoue et ffmpeg **retombe en logiciel** : `utime` remonte à
10,96 s. Corollaire : le microcode chargé est bien celui-là, et il est
indispensable.

Autre preuve : `grep -c queue_decode` sur la trace debug d'une passe matérielle
donne **180**, soit une soumission par image du flux — le chemin
`v4l2_request_queue_decode()` a bien servi 180 fois.

### Ce que cette mesure ne dit pas

- Rien sur **HEVC, VP9 ou MPEG-2** : seuls les formats sont annoncés.
- Rien sur l'affichage : la sortie était `-f null`, donc aucun consommateur DRM
  n'a touché le descripteur à deux objets.
- Rien sur **Kodi**, qui passe par le même `ff_v4l2_request_init()` mais avec un
  renderer DRM PRIME.

### Vérifié sur l'image finale, sans béquille

Image `c5c32781…` (les quatre patchs) flashée puis bootée ; `ffmpeg` =
`/run/current-system/sw/bin/ffmpeg`, microcodes présents et **non compressés**
(13 entrées, 0 `.zst`), aucun `LD_LIBRARY_PATH`, aucun `firmware_class.path`.
Les quatre codecs, 1080p30, 6 s de flux :

| codec | pixels matériel vs logiciel | `utime` mat. / log. | `rtime` mat. / log. |
|---|---|---|---|
| H.264 | **md5 identiques** (`4fa46ae3…`) | 5,05 s / 10,96 s (÷ 2,2) | 5,64 s / 3,21 s |
| HEVC | **md5 identiques** (`80af60ff…`) | 5,30 s / 15,70 s (÷ 3,0) | 5,57 s / 4,41 s |
| VP9 | **md5 identiques** (`4377b2ac…`) | 4,96 s / 8,01 s (÷ 1,6) | 5,36 s / 2,50 s |
| MPEG-2 | md5 différents, **PSNR 68 dB** | 5,39 s / 3,01 s | 7,23 s / 1,30 s |

L'égalité des empreintes pour H.264, HEVC et VP9 est le point important :
`-f null` jette les images, donc une mesure de temps seule ne prouve que « ça ne
plante pas ». Elle prouve maintenant que le VPU produit exactement les mêmes
pixels que le logiciel.

Le MPEG-2 fait exception, et c'est **attendu** : sa norme spécifie l'IDCT avec
des tolérances (annexe A), donc deux décodeurs corrects peuvent différer de ±1.
Le md5 diffère, le PSNR est de 68 dB — même image, arrondis différents. C'est la
bonne mesure pour ce codec ; conclure « défaut » sur le md5 seul serait faux.

### Image reconstruite avec les quatre correctifs (flashée et vérifiée)

`0002` (NV12M), `0003` (sonde VP9) et `0004` (tranches HEVC) sont désormais tous
dans le lock. Image reconstruite le 2026-10-28 :

```sh
nix build .#packages.aarch64-linux.magicsee-n5-decode-image \
  --override-input nixbian path:/tmp/opencode/nixbian-vdec
```

| | valeur |
|---|---|
| sortie | `/nix/store/p6ck268h8pz2lqprg035w797ygxz8wq5-nixelec-meson64-aml-s9xx-box.img` |
| compressée | 475 442 133 octets |
| brute | 2 667 577 344 octets |
| `sha256` (`.img.zst`) | `c5c327817b2826ef11a82614fcc55dd7fba6ca9a14704ad1f8d59b45b9832e6d` |
| contenu vérifié | `xg4fyn8p…-ffmpeg-6.1.6-lib` (les quatre patchs), 13 fichiers de microcodes, **0 `.zst`** |

⚠️ **Le pin `nixbian` du lock (`038d3092`) ne contient pas
`metadata/nix/patches/kernel/meson64-vdec-7.0`.** Sans l'`--override-input`
ci-dessus, l'évaluation retombe silencieusement sur le noyau par carte, donc
**sans le driver VPU** : l'image se construit quand même, et le décodage matériel
disparaît. Le seul signe est l'avertissement
`nixelec: le pin nixbian ne contient pas les patchs meson64-vdec-7.0`. Rendre
l'image reproductible depuis le lock seul demande de pousser la branche
`feat/meson64-vdec-7.0` côté nixbian et de bouger le pin.

## Pourquoi le VPU décharge le CPU sans accélérer

Constat à expliquer : `utime` divisé par 2 à 3, mais `rtime` **supérieur** au
logiciel (5,5 s contre 3,3 s pour 6 s de flux 1080p).

### Ce n'est pas le parsing

L'explication spontanée — « le stateless laisse le parsing au CPU » — est vraie
sur le principe mais **fausse comme terme dominant**. Le balayage en résolution,
même codec, même durée, le montre :

| résolution | pixels | `utime` matériel | `utime` logiciel | `rtime` matériel | `rtime` logiciel |
|---|---|---|---|---|---|
| 640×360 | 0,23 Mpx | 0,658 s | 1,253 s | 0,808 s | 0,498 s |
| 1280×720 | 0,92 Mpx | 2,257 s | 4,472 s | 2,494 s | 1,458 s |
| 1920×1080 | 2,07 Mpx | 5,132 s | 10,883 s | 5,472 s | 3,251 s |

Deux faits écartent le parsing :

1. le coût matériel est **linéaire en pixels** — ×4,7 de pixels, ×4,7 de CPU ;
2. à 1080p il vaut ~5 s pour **les quatre codecs** : H.264 5,0 ; HEVC 5,3 ;
   VP9 5,05 ; MPEG-2 5,5 — alors que leurs parsings n'ont rien de comparable.

### Ce que c'est : le trafic mémoire des buffers de sortie

Un coût indépendant du codec et proportionnel aux pixels est un coût de
**données**, pas de bitstream. Chaque image 1080p en NV12M pèse 3,1 Mio ; sur
180 images cela fait 560 Mio, écoulés en 5,1 s, soit ~110 Mo/s — l'ordre de
grandeur d'une maintenance de cache sur un DMA non cohérent sur cette puce.

C'est l'hypothèse la mieux étayée, pas une preuve : la confirmer demanderait
`perf` sur la cible, absent de l'image. Elle a l'avantage de prédire correctement
les quatre codecs et les trois résolutions.

### Trois autres pistes, réfutées par la mesure

| hypothèse | test | résultat |
|---|---|---|
| overhead par tranche | ré-encoder avec `slices=4` (4 requêtes/image) | **4,986 s** contre 4,98–5,01 s → aucun effet |
| allocation de buffers par image | compter `buffer_alloc` | 22 frames allouées pour 180 images → pool, non |
| copie de retour (`hwdownload`) | `grep -c` sur la trace debug | **0** → aucune copie logicielle |

Le discriminant est `utime/rtime` = **5,0 / 5,33 = 0,94** : le processus est
CPU-bound, il n'attend pas le VPU. Ce n'est donc pas non plus une latence du
matériel.

Ce que le stateless déplace est réel — userspace parse le CABAC, gère le DPB et
pousse les paramètres par contrôles V4L2, le VPU ne fait que l'IDCT, la
compensation de mouvement et le déblocage — mais ce n'est pas ce qui coûte 5 s
ici : la mesure ci-dessus le montre.

### Pourquoi le temps mural reste pire

Le chemin matériel est strictement séquentiel — une requête en vol,
`MEDIA_REQUEST_IOC_QUEUE`, `select()` bloquant, deux `DQBUF`, puis
`MEDIA_REQUEST_IOC_REINIT` — sur **un** fil, tandis que le logiciel répartit
parsing et reconstruction sur 3,4 cœurs. À 1080p : 28 ms par image sans
recouvrement, contre 18 ms de CPU par image réparties sur quatre cœurs.

**Corollaire pour la suite :** le plancher n'est ni le VPU ni le parsing, c'est
le trafic mémoire des buffers. Pipeliner plusieurs requêtes ne le supprimerait
pas ; seul un consommateur qui ne ramène jamais les images en mémoire système
(un lecteur qui scanne les dmabufs, type Kodi) éviterait cette dépense. Le VPU
sert à **libérer du CPU**, pas à augmenter le débit d'un `ffmpeg -f null`.

Conséquence pour le MPEG-2 : son logiciel coûte 3,1 s à 1080p, sous le plancher
matériel de ~5,5 s. Aucun réglage ne le rendra gagnant à cette résolution ;
c'est une politique de routage, pas un correctif.

## Autres codecs : HEVC, VP9, MPEG-2 (mesuré le 2026-10-28)

Les formats sont **annoncés** (`S265`, `VP9F`, `MG2S`) ; restait à savoir s'ils
décodent. Échantillons produits sur l'hôte (ffmpeg 8.1.2), poussés par le lien
Ethernet direct, tous les microcodes `meson/vdec/*.bin` présents et
`firmware_class.path = /tmp/fw` :

```sh
ffmpeg -f lavfi -i "testsrc2=size=1920x1080:rate=30:duration=6" \
  -c:v libx265 -preset ultrafast -x265-params "keyint=60:scenecut=0" -f hevc  sample-1080p.hevc
ffmpeg … -c:v libvpx-vp9 -b:v 4M -g 60 -deadline realtime -cpu-used 8 -f ivf  sample-1080p.ivf
ffmpeg … -c:v mpeg2video -b:v 8M -g 60 -f mpeg2video                        sample-1080p.m2v
```

| codec | logiciel (`utime`) | `-hwaccel drm` | verdict |
|---|---|---|---|
| H.264 | 10,87–10,97 s | **4,98–5,01 s** | VPU, CPU ÷ 2,2 |
| HEVC | 15,68–15,74 s | **5,32 s** (rtime 5,57 s) | VPU, bit-exact, CPU ÷ 3,0 |
| VP9 | 8,05–8,08 s | **5,05 s** (rtime 5,39 s) | VPU, bit-exact, CPU ÷ 1,6 |
| MPEG-2 | 3,12–3,13 s | 5,47–5,53 s (rtime 7,3 s), PSNR 68 dB | VPU, correct mais **plus lent** que le logiciel |

### HEVC : un seul verrou, désormais levé

```text
ff_v4l2_request_query_control: query control failed, Invalid argument (22)
v4l2_request_hevc_set_controls: unsupported max slices, 800
```

`S265` est annoncé, et le driver **crée bien** `SLICE_PARAMS` — avec
`AMVDEC_HEVC_MAX_SLICES = 800` (`amlogic-0119`, l.1482). C'est ffmpeg qui code en
dur `MAX_SLICES 600` (`v4l2_request_hevc.c:24`) et refuse la négociation.
Correctif `0004` : aligner l'array sur la capacité réelle du driver.

Après correctif :

| contrôle | résultat |
|---|---|
| sonde | `Using V4L2 media device /dev/media0 (meson-amvdec) for S265` |
| capacités | `frame based, supports slices 1, scaling_matrix: 1, max slices: 800` |
| pixels, 10 images | **md5 identiques** (`80af60ff…`) → bit-exact |
| `utime` matériel / logiciel | 5,317 s / 15,769 s (**÷ 2,97**) |
| `rtime` matériel / logiciel | 5,571 s / 4,514 s |

Le `query control failed, EINVAL` qui subsiste porte sur `entry_point_offsets`,
optionnel (`supports_entry_point_offsets: 0`) : sans conséquence.

**Réserve** : `amvdec` exige aussi `EXT_SPS_ST_RPS`, que cette série ne pose
pas. Cet échantillon (HEVC Main, RPS portés par le SPS) passe bit-exact ; un flux
qui signale des RPS courts étendus hors SPS demandera la série detlev
(FFmpeg 7.x). Le verrou n'est donc pas universel — ne pas annoncer « HEVC
validé » sans cette nuance.

### VP9 : le probe envoyait un descripteur invalide — corrigé

```text
[vp9] No V4L2 media device found for VP9F
Failed setup for format drm_prime: hwaccel initialisation returned error.
```

`v4l2_request_vp9_init()` appelle `fill_frame()` alors qu'aucun en-tête n'a
encore été analysé : `bit_depth` vaut 0, les drapeaux de sous-échantillonnage
sont absents et les dimensions valent -1. Le `try_ctrl` du driver
(`amlogic-0123`) exige un descripteur cohérent et rejette par `EINVAL`, ce qui
fait échouer la découverte du périphérique — alors que le matériel est capable.
Le diagnostic est venu du log `debug` (`set controls failed, EINVAL`), pas de
l'énumération udev.

Correctif dans `nix-v4l2-request` (`0003`) : sonder avec un descripteur de
référence valide (profil 0, 8 bits, 4:2:0, dimensions de `avctx`) ; les contrôles
par image portent ensuite les paramètres réels.

Après correctif, bibliothèque poussée à chaud sur l'image de qualification :

| contrôle | résultat |
|---|---|
| sonde | `Using V4L2 media device /dev/media0 (meson-amvdec) for VP9F` |
| pixels, 10 images | **md5 identiques** (`4377b2ac…`) → décodage bit-exact |
| requêtes VPU | 185 pour 180 images |
| `utime` matériel / logiciel | 5,052 s / 8,048 s (÷ 1,6) |
| `rtime` matériel / logiciel | 5,393 s / 2,575 s |

### MPEG-2 : le VPU travaille, et c'est un mauvais échange

Pas de message d'échec, et le test de contrôle le confirme — microcode
`gxl_mpeg12_multi.bin` retiré :

```text
Direct firmware load for meson/vdec/gxl_mpeg12_multi.bin failed with error -2
Failed setup for format drm_prime: hwaccel initialisation returned error.
bench: utime=3.163s stime=0.144s rtime=1.330s
```

Donc avec le microcode le VPU décode bien, et **correctement** : les pixels
matériels diffèrent du logiciel au md5, mais à **68 dB de PSNR** — l'IDCT MPEG-2
est spécifiée avec tolérances, ces écarts de ±1 sont normaux et ne sont pas un
défaut. En revanche le chemin matériel coûte **plus** de CPU (5,39 s contre
3,01 s) et met 7,2 s pour 6 s de flux : sur cette A53, le MPEG-2 logiciel est
meilleur sur les deux critères. Ne pas présenter MPEG-2 comme une accélération,
et ne pas le router vers le VPU.

### Conclusion honnête sur les codecs

**H.264, HEVC et VP9** décodent par le VPU, bit-exact, avec un CPU divisé par
2,2, 3,0 et 1,6 respectivement — mais un temps mural supérieur au logiciel, pour
la raison décrite plus bas. **MPEG-2** décode mais régresse. Le driver noyau
implémente les quatre codecs ; les trois blocages tenaient à la série ffmpeg et
sont corrigés par `0002`, `0003` et `0004`.

## Sources amont à réutiliser (relevé du 2026-10-28)

Rien de ce qui manque n'est à écrire depuis zéro : le travail existe en amont,
il faut le brancher. Chaque entrée ci-dessous a été ouverte, pas citée de
mémoire.

| besoin | source | ce qu'elle apporte |
|---|---|---|
| noyau, tous codecs | `LibreELEC/LibreELEC.tv` → `projects/Amlogic/patches/linux/`, commit `96d9f0fb` | série complète `0117`–`0210`. nixbian en vend déjà `0118`–`0128` : MPEG-2 (`0120`), HEVC (`0122`), VP9 (`0123`) **sont appliqués**. Côté noyau il n'y a rien à réécrire. |
| HEVC, 1er refus | `amlogic-0119` l.1482 : `#define AMVDEC_HEVC_MAX_SLICES 800` | ffmpeg code en dur `MAX_SLICES 600` (`v4l2_request_hevc.c:24`) et refuse : « unsupported max slices, 800 ». Une constante à aligner. |
| HEVC, contrôle manquant | `LibreELEC.tv` → `packages/multimedia/ffmpeg/patches/detlev/0001-hevc-Add-support-for-sps_st_rps-control.patch` | ajoute `hevc_ext_sps_st_rps` / `lt_rps`, exigés par `amvdec`. Cible **FFmpeg 7.x** (`libavcodec/hevc/ps.c`), donc implique une migration 6.1.6 → 7.x, et Kodi 21 → 22 pour la soname. |
| ffmpeg v4l2-request | `LibreELEC.tv` → `packages/multimedia/ffmpeg/patches/v4l2-request/` | `0001-v4l2-request.patch` (notre base, rebasée 6.1.6) + `0002-v4l2-request-vc1.patch` (VC-1, hors besoin). |
| Kodi, descripteur NV12M | `xbmc/xbmc` → `DRMPRIMEEGL.cpp` l.86-89 et `VideoLayerBridgeDRMPRIME.cpp` l.125/145 | les deux chemins résolvent `descriptor->objects[layer->planes[i].object_index]` : **un descripteur à deux objets est supporté**, seule contrainte `nb_layers == 1` (la nôtre). Kodi n'a pas besoin d'être patché. |
| microcodes | `LibreELEC/meson-firmware` @ `662b843` | déjà intégré (`decode-tools.nix`). |

Lecture qui en découle :

- **HEVC** : deux verrous ffmpeg, pas un chantier noyau. Le premier est une
  constante ; le second impose FFmpeg 7 + Kodi 22.
- **VP9** : contrôles présents dans la série 6.1.6, donc le diagnostic est côté
  `v4l2_request_vp9.c` — à instruire avant de conclure.
- **MPEG-2** : le README du jeu de patchs le dit déjà « non validé avec Kodi »,
  et la mesure montre qu'il régresse ; c'est une politique de routage, pas un
  correctif.
- **Kodi** : plus de risque « descripteur refusé ». Le risque restant est le
  rendu lui-même (EGL/GBM sur GXL), pas le format.

## État

- [x] `H264_SLICE` mesuré, `/dev/media0` présent, ffmpeg patché vérifié par le
      test C, échantillon et script embarqués
- [x] décodage 1080p mesuré le 2026-10-28 → **échec, repli logiciel** (avant
      patch)
- [x] cause racine identifiée (`NV12M` vs `NV12`), avec trace et enum
- [x] piste driver écartée sur preuve (driver strictement multi-plan)
- [x] patch ffmpeg multi-plan `0002` écrit et appliqué au build
- [x] microcodes VPU ajoutés, compression firmware corrigée (mesuré)
- [x] décodage **re-mesuré avec `0002`** : `utime` 4,98–5,01 s contre
      10,87–10,97 s en logiciel, 180 soumissions `queue_decode`
- [x] expérience de contrôle : microcode retiré → hwaccel KO, retour logiciel
      à 10,96 s
- [x] baseline chiffrée : logiciel 10,9 s de CPU en 3,2 s pour 6 s de 1080p,
      matériel 5,0 s de CPU en 5,3 s
- [x] HEVC / VP9 / MPEG-2 **mesurés** le 2026-10-28 : HEVC et VP9 ne décodent
      pas, MPEG-2 décode mais régresse (5,5 s de CPU contre 3,1 s en logiciel)
- [x] **VP9 rétabli** : cause racine = descripteur de sonde invalide côté
      ffmpeg, correctif `0003` ; bit-exact, `utime` 5,05 s contre 8,05 s,
      185 requêtes VPU pour 180 images
- [x] **HEVC rétabli** : `MAX_SLICES` 600 → 800 (`0004`) ; bit-exact,
      `utime` 5,32 s contre 15,77 s (÷ 3,0) ; réserve RPS étendu documentée
- [x] analyse de performance : `utime/rtime = 0,94` → CPU-bound ; coût matériel
      **linéaire en pixels et indépendant du codec** (balayage 360p/720p/1080p)
      → trafic mémoire des buffers, pas parsing ; trois pistes réfutées
- [x] image de qualification flashée et bootée : microcodes présents et non
      compressés, ffmpeg patché par défaut, décodage H.264 **bit-exact** vérifié
- [ ] Kodi : descripteur à deux objets supporté par `DRMPRIMEEGL` et
      `VideoLayerBridgeDRMPRIME` (lecture du code) — reste à valider au rendu
- [ ] HEVC : aligner `MAX_SLICES` (600 ↔ 800 côté driver), puis poser le
      contrôle `EXT_SPS_ST_RPS`, ce qui implique FFmpeg 7.x
