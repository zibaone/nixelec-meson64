# Étude — porter l'encodeur H.264 de `meson-sm1-codecs` (SM1) vers GXL S905L

> **Statut** : pré-étude, aucune ligne de code noyau écrite, rien de mesuré à
> l'exécution (N5 injoignable : `.21`/`.67` en timeout au 2026-11-04).
> **Date** : 2026-11-04. **Driver** : `github.com/ray38080289/meson-sm1-codecs`
> @ `eb7a44464af1c7793f793698e309abe4e6ad82da` (2026-10-09), GPL-2.0.
> **Cible** : Magicsee N5, GXL **S905L**, noyau `meson64-edge` **7.0.14**,
> décodeur `meson-amvdec` stateless (`nixelec.vpu.mode = "stateless"`).

## 1. Objet et périmètre

Le driver d'encodeur H.264 écrit pour SM1 peut-il être porté sur le GXL de la N5,
et à quel coût ?

| Élément | Périmètre | Motif |
|---|---|---|
| `venc-h264/` (`amvenc_avc`, `meson-venc-h264`, CLI `venc`) | **oui** | seul encodeur matériel du GXL |
| `venc-hevc/` (WAVE420L) | non | IP Chips&Media absente du GXL ; le S905L n'annonce que JPEG + H.264 |
| `vdec/` (`meson-vdec` stateful) | non | la N5 décode en stateless ; les deux ne s'empilent pas |
| JPEG encode (`gxl_jpeg_enc.bin`) | plus tard | l'ucode existe (§8), pas de driver dans le projet |

Cette étude ne tranche ni l'API userspace, ni l'usage (NVR, transcode, kiosque),
ni la licence du microcode. Elle établit ce qui est réutilisable, ce qui manque,
et où sont les inconnues.

## 2. Ce que le driver SM1 apprend

| Fichier | Lignes | Rôle |
|---|---|---|
| `venc-h264/encoder.c` | 5 444 | cœur vendor 4.9 : HCODEC, ucode, RC, ISR |
| `venc-h264/venc_v4l2.c` | 827 | façade V4L2 M2M (`meson-venc-h264`) |
| `venc-h264/compat.c` | 230 | glue mainline : DT, IRQ, clocks, canvas, CMA |
| `venc-h264/compat.h` | 182 | substituts des APIs vendor (`codec_mm`, `get_cpu_type`…) |
| `venc-h264/venc.c` | 261 | CLI sur le chardev `/dev/amvenc_avc` (ioctls propriétaires) |

Architecture : **cœur vendor conservé** + **couche `compat` qui lui fait croire
qu'il tourne sur un noyau vendor** + **façade V4L2 M2M par-dessus**. C'est ce qui
rend le port abordable : le cœur ne connaît ni V4L2 ni mainline.

Deux interfaces sur le même état : V4L2 M2M (`OUTPUT` NV12/NV21 1 ou 2 plans,
`CAPTURE` H.264 Annex-B, `V4L2_CAP_VIDEO_M2M_MPLANE`, `venc_v4l2.c:801`) et le
chardev pour le CLI. Contrôles exposés (`venc_v4l2.c:654-699`) : bitrate, RC
frame-level, GOP, QP I/P/min/max, `FORCE_KEY_FRAME`, B-frames figé à 0, **profil
figé à Main**, niveau figé à 4.0 ; un changement prend effet au stream suivant.

**Firmware** : `get_data_from_name()` (`compat.c:41-56`) cherche
`meson/venc/<nom>.bin` par `request_firmware()`, donc
`/lib/firmware/meson/venc/gxl_h264_enc.bin`. La table `ucode_name[]`
(`encoder.c:445-449`) donne `gxl_h264_enc` (CAVLC), `txl_h264_enc_cavlc`,
`ga_h264_enc_cabac` : **le GXL n'a pas de CABAC**, c'est l'IP, pas un choix.

**Mémoire** : `amvenc_buffspec[]` (`encoder.c:397-436`) = un bloc contigu de
`0x1400000` (**20 MiB**) par instance, plus les buffers d'entrée vb2.
`max_instance = cma_pool_size / MIN_SIZE`, `cma_pool_size = min(3 × MIN_SIZE,
codec_mm_get_total_size())` (`encoder.c:5040`, `compat.h:142` → 256 MiB) :
**3 instances, 60 MiB de CMA au plus**. L'allocation passe par
`dma_alloc_pages()` → `dma_alloc_contiguous()` (`kernel/dma/direct.c:132`), donc
par la **CMA globale**.

## 3. Vérification matérielle GXL

### 3.1 Ce que le SoC annonce

*S905L Quick Reference Manual* (juin 2016, relayé par CNX Software le 2016-09-20
et androidtvbox.eu) : « Independent JPEG and H.264 encoder with configurable
performance/bit-rate […] **H.264 video encoding up to 1080P@60fps with low
latency** », et « supports […] **simultaneous decoding and encoding** ». Le S905L
est un S905X sans VP9/caméra/TS ; l'encodage est identique. Aucun encodeur HEVC
sur GXL. Cible réaliste : **H.264 1080p60, Main, CAVLC**.

### 3.2 Le code vendor contient déjà le chemin GXL

`pannal/media_modules-aml` `amlogic-4.9.269`,
`drivers/frame_sink/encoder/h264/encoder.c` (4 900 l.) :

| Preuve | Commande | Résultat |
|---|---|---|
| table d'ucodes | `grep -n gxl_h264_enc encoder.c` | `449: "gxl_h264_enc",` |
| branche GXL | `grep -n MESON_CPU_MAJOR_ID_GXL encoder.c` | `2304`, `3471` (DEVINFO) |
| power-on GXL | `sed -n '2638,2680p' encoder.c` | `PWR_CNTL_REG0 & ~0x18`, `SLEEP0 & ~0x3`, `ISO0 & ~0x30` |

Le fork a recopié ce fichier en gardant les branches ; elles sont compilées mais
**jamais exécutées**, parce que `compat.h:117` renvoie SM1 en dur :
`static inline int get_cpu_type(void) { return MESON_CPU_MAJOR_ID_SM1; }`.

### 3.3 Le DT mainline fournit plus que ce qu'on croyait

L'hypothèse « le nœud `vdec` mainline n'a pas de clocks » est **fausse en
7.0.14** (`arch/arm64/boot/dts/amlogic/meson-gxl.dtsi:971-979`) :

```
&vdec {
        compatible = "amlogic,gxl-vdec", "amlogic,gx-vdec";
        clocks = <&clkc CLKID_DOS_PARSER>, <&clkc CLKID_DOS>,
                 <&clkc CLKID_VDEC_1>, <&clkc CLKID_VDEC_HEVC>;
        clock-names = "dos_parser", "dos", "vdec_1", "vdec_hevc";
};
```

Vérifiés dans le même arbre : `amlogic,ao-sysctrl` et `amlogic,canvas` sur le
nœud `vdec` (`meson-gx.dtsi:551-553`), `amlogic,meson-gx-hhi-sysctrl` (`:590`),
`arm,gic-400` (`:442`), canvas `video-lut@48`/`amlogic,canvas` (`:576-579`).
Tout ce que `compat.c` consomme existe — sauf le `compatible`.

## 4. Analyse des écarts

| # | Écart | Gravité | Effort |
|---|---|---|---|
| 1 | `of_find_compatible_node("amlogic,sm1-vdec")` | bloquant, trivial | minutes |
| 2 | `select_ucode()` ne rend jamais `gxl_h264_enc` | bloquant | ~1 h |
| 3 | `get_cpu_type()` = SM1 en dur | bloquant (branches GXL mortes) | ~1 h |
| 4 | `AO_RTI_PWR_CNTL_REG0` neutralisé | **inconnu** — cœur du risque | 0,5–2 j |
| 5 | horloge HCODEC : macro au mauvais format de champs | **inconnu** | 0,5–2 j |
| 6 | IRQ `mailbox_2` | **non-écart** (vérifié = SPI 45) | 0 |
| 7 | API noyau 7.0.14 | **non-écart** (compilé) | 0 |
| 8 | firmware `gxl_h264_enc.bin` | **non-écart** (trouvé) | 0,5 j packaging |
| 9 | partage du bloc DOS avec `amvdec` | à mesurer | 1 j |

**4.1 — Nœud DT (écart 1).** `compat.c:160` cherche `"amlogic,sm1-vdec"` ; sur
GXL le nœud est `"amlogic,gxl-vdec", "amlogic,gx-vdec"`. Chercher
`"amlogic,gx-vdec"` couvre GXBB/GXL/GXM. Échec propre (`-ENODEV`, module non
chargé), pas de crash.

**4.2 — IRQ (écart 6, non-écart).** `compat.c:23` code `HCODEC_MBOX2_SPI 45`.
Vérification dans le DT vendor GXL (`gxl_p212_2g.dts`, CoreELEC `amlogic-4.9-20`,
l. 509-522) : `interrupts = <0 3 1 0 23 1 0 32 1 0 43 1 0 44 1 0 45 1>`,
`interrupt-names = "vsync", "demux", "parser", "mailbox_0", "mailbox_1",
"mailbox_2"`. Donc **mailbox_2 = GIC SPI 45** : la constante est juste pour GXL.
Mainline prend 44 (`vdec`) et 32 (`esparser`) ; 45 est libre. Pas de collision de
registre non plus : le décodeur utilise `ASSIST_MBOX1_CLR/MASK` (`0x1d4`/`0x1d8`),
l'encodeur `HCODEC_ASSIST_MBOX2_*` (`0x1078`-`0x107b`, `hcodec_regs.h:88-91`).

**4.3 — Horloge (écart 5).** `encoder.h:78-95` écrit `HHI_VDEC_CLK_CNTL`
(`0x1e0`) avec `mux << 25`, `1 << 24`, div dans `[15:0]`. Le CCF mainline décrit
ce registre autrement pour GXL (`drivers/clk/meson/gxbb.c`) :

| Champ | Position | Source |
|---|---|---|
| `vdec_1_sel` (mux) | `[10:9]` | `gxbb.c:2566-2572` |
| `vdec_1` (gate) | bit 8 | `gxbb.c:2600-2604` |
| `vdec_1_div` | `[6:0]` | `gxbb.c:2582-2588` |

Le format `mux[26:25] / enable[24] / div[22:16]` est celui de
`HHI_VDEC2_CLK_CNTL` (`0x1e4`, l'horloge HEVC — `gxbb.c:2616-2638`). Sur GXL la
macro écrit donc dans des champs non documentés et **n'active pas la gate bit 8**.
Aggravant : mainline n'expose **aucune** horloge `hcodec` (le vendor a un
`clk_hcodec_mux`, absent du CCF). Deux voies à trancher en P1/P2 : laisser
`amvdec` activer `vdec_1` (666 MHz par session) et le vérifier dans
`clk_summary`, ou reproduire `set_vpu_clk` du vendor avec le bon format.
**Non vérifié** : laquelle suffit.

**4.4 — Alimentation (écart 4).** `avc_poweron()` (`encoder.c:2958-3035`) prend
pour tout SoC < SC2 le chemin GXL : `PWR_CNTL_REG0 &= ~0x18`, `SLEEP0 &= ~0x3`,
`DOS_SW_RESET1` ~0 puis 0, `hvdec_clock_enable()`, `DOS_MEM_PD_HCODEC = 0`,
`ISO0 &= ~0x30`, bascule `DOS_GEN_CTRL0[0]`. Mais `compat.h:63` remplace
`AO_RTI_PWR_CNTL_REG0` par un sentinelle `0xffff` et `venc_ao_read/write()`
**ignorent** cette adresse :

```c
/* vendor clears bits [4:3] of this on SM1; mainline never touches it and M1
 * powered HCodec fine without, so accesses to it are dropped. */
#define AO_RTI_PWR_CNTL_REG0  0xffff
```

Le commentaire parle de SM1. Sur GXL le vendor fait bien cette écriture
(`pannal/…/encoder.c:2648` ; `jpegenc.c:2867` fait de même pour le JPEG) : c'est
la **seule ligne du chemin GXL qui a été neutralisée**, et celle dont on ne sait
pas si elle est nécessaire. Point rassurant, vérifié : les bits AO de l'encodeur
(`[1:0]`, `[5:4]`) ne recoupent pas ceux d'`amvdec` (`GEN_PWR_VDEC_1 =
BIT(3)|BIT(2)`, `GEN_PWR_VDEC_1_ISO = BIT(7)|BIT(6)`, `amlogic-0119`), ni le
domaine VPU global (`SLEEP0` bit 8 / `ISO` bit 9, `meson-ee-pwrc.c:85-90`).
**Non vérifié** : sémantique de `PWR_CNTL_REG0[4:3]` sur GXL et l'offset AO réel
— le fork ne le connaît plus, les copies publiques du 4.9 consultées ne le
définissent pas ; à récupérer du BSP complet.

**4.5 — Ucode (écart 2).** `encoder.c:643-668` : le `switch` par type de CPU est
sous `#if 0`, et le code actif fait `UCODE_MODE_FULL → UCODE_G12A`. Tous les
appelants passent `UCODE_MODE_FULL` (`:3819`, `:3858`, `:4383`) : le driver charge
**toujours `ga_h264_enc_cabac`**, un ucode G12A/SM1. Sur GXL, au mieux il échoue
au chargement, au pire il pend le HCODEC. Rétablir la sélection par
`get_cpu_type()` est le changement le plus simple et le plus indispensable.

**4.6 — `get_cpu_type()` (écart 3).** Une fois `compat.h:117` à
`MESON_CPU_MAJOR_ID_GXL`, les branches GXL s'activent : `:2608`
(`V4_FORCE_SKIP_CFG` + `V3_SKIP_*`), `:4028` (DEVINFO rend `AML-GXTVBB`, comme le
vendor) ; les branches `>= GXTVBB`/`>= TXL` restent vraies, celles `>= SC2`
(`:2730`, `:2965`, `:3016`, `:3041`, `:3079`, `:3103`) deviennent fausses — ce
qui est voulu. Elles sont compilées dans le même objet, donc peu de bit-rot, mais
**non vérifié** : personne ne les a exécutées depuis le fork.

**4.7 — API 7.0.14 (écart 7, non-écart).** Le module **compile sans erreur**
contre l'arbre de build du noyau edge de la N5 (7.0.14, config Armbian) :

```
$ make -C <kernel-dev>/lib/modules/7.0.14/build M=$PWD/venc-h264 \
       ARCH=arm64 CROSS_COMPILE=aarch64-unknown-linux-gnu- modules
  CC [M] encoder.o … compat.o … venc_v4l2.o → LD [M] amvenc_avc.ko
$ echo $?   # 0     $ ls -l amvenc_avc.ko → 1 677 784 o
$ strings amvenc_avc.ko | grep vermagic
vermagic=7.0.14 SMP preempt mod_unload aarch64
```

14 avertissements : 13 `-Wmissing-prototypes` (style vendor) + 1 « pahole
version differs ». Les symboles existent en 7.0.14 (`v4l2_m2m_ioctl_encoder_cmd`,
`v4l2_m2m_is_last_draining_src_buf`, `v4l2_m2m_update_start_streaming_state`,
`platform_device_register_simple`), et `meson_canvas_alloc/free/config` sont
`EXPORT_SYMBOL_GPL` (`drivers/soc/amlogic/meson-canvas.c:125-164`). La config
fournit déjà `MEDIA_SUPPORT=m`, `VIDEO_DEV=m`, `V4L2_MEM2MEM_DEV=m`,
`VIDEOBUF2_DMA_CONTIG=m`, `MESON_CANVAS=y`, `CMA=y`. **L'API n'est pas le
risque**, contrairement à `note-integration-meson-sm1-codecs.md:97-100`.

**4.8 — Partage du bloc DOS (écart 9).** Les deux drivers mappent la même fenêtre
`0xc8820000` : `amvdec` par `devm_platform_ioremap_resource_byname(pdev, "dos")`
(revendique la région), `compat.c:183` par un `ioremap` nu. Pas de conflit
d'allocation, mais **aucun verrou commun** :

| Registre | `amvdec` | encodeur |
|---|---|---|
| `DOS_SW_RESET0` / `DOS_MEM_PD_VDEC` | oui | non |
| `DOS_SW_RESET1` / `DOS_MEM_PD_HCODEC` | non | oui |
| `DOS_GCLK_EN0` | `0x3ff` (bits 0-9) | `0x7fff << 12` (bits 12-26) |
| `DOS_GEN_CTRL0` | `= 0` (`amlogic-0119`, `amvdec_1_conf_esparser`) | bascule bit 0 |
| `HHI_VDEC_CLK_CNTL` | via `vdec_1` (CCF) | écriture directe (§4.3) |

Les jeux de bits sont disjoints sauf `DOS_GEN_CTRL0` : une session de décodage
qui démarre pendant un encodage peut éteindre un gate de l'encodeur. **Non
mesuré** — candidat n°1 aux bugs « ça marche seul, ça casse en transcode ».

**4.9 — CMA.** 1080p : 20 MiB de bloc + entrée NV12 1920×1088 (3,1 MiB par
buffer, 4 à 6 buffers) + bitstream, alors que le décodeur consomme déjà la CMA
globale pour sa DPB. `cma=128M` est **plausible mais non mesuré** ; le levier est
`cma=192M`/`256M` dans `boot.kernelParams`.

## 5. Plan par phases et gates

**P0 — packaging (0,5 j).** `pkgs/amvenc-avc.nix` (`make -C
${kernel.dev}/lib/modules/${kernel.modVersion}/build M=… modules`, noyau
**nixbian**, pas nixpkgs) ; `boot.extraModulePackages` (déjà repris dans
`system.modulesTree`, `parts/modules.nix:140`) ; firmware séparé via
`nixelec.extraFirmware`. *Gate* : `vermagic` = `7.0.14`, `insmod` sans Oops,
`dmesg` montre `amvenc: dos … irq …` ou l'échec propre `-ENODEV`.

**P1 — probe GXL (1–2 j) — décision.** Écarts 1 et 3. Vérifier à l'exécution
`dos_clk` par `of_clk_get_by_name`, 12 canvas consécutifs, IRQ 45. *Gate* :
`v4l2-ctl --list-devices` montre `meson-venc-h264` ; `--list-formats-out` liste
`NV12M`/`NV21M` (file OUTPUT) et `--list-formats` liste `H264` (file CAPTURE) ;
`dmesg` sans WARN ; décodage bit-exact non régressé.

**P2 — première frame (1–2 j) — décision.** Écart 2 (ucode GXL) puis écarts 4 et
5 **par la mesure** : `clk_summary` avant/après, `devmem` sur `SLEEP0`/`ISO0`, un
seul changement à la fois. *Gate* : une frame 1080p encodée, décodée en logiciel,
PSNR ≥ 35 dB ; puis 1080p30 en continu ; `dmesg` propre.

**P3 — cohabitation (1 j).** *Gate* : décodage bit-exact toujours vert avec
`amvenc_avc` chargé ; transcode 1080p 10 min sans erreur ; CMA et thermique
relevés ; pas de régression Kodi.

**P4 — intégration (1–2 j).** Option `nixelec.venc.h264.enable` (défaut `false`),
firmware, paquet module, `nix flake check`, doc carte. *Gate* : image construite,
cold boot, `/dev/video*` présent, encode reproductible après reboot,
`nixelec.vpu.mode` inchangé.

## 6. Estimation d'effort

| Phase | Effort | Risque |
|---|---|---|
| P0 packaging | 0,5 j | faible (compilation déjà prouvée) |
| P1 probe | 1–2 j | moyen (canvas, ordre de probe) |
| P2 première frame | 1–2 j | **élevé** (alimentation + horloge non documentées) |
| P3 cohabitation | 1 j | moyen (registres DOS partagés) |
| P4 intégration | 1–2 j | faible |
| **Total** | **4,5–7,5 j** | dont 2 j avant le premier gate sérieux |

## 7. Risques et critères d'abandon

| Risque | Prob. | Impact | Parade |
|---|---|---|---|
| Alimentation HCODEC GXL non documentée (§4.4) | moyenne | chantier bloqué | `devmem` + comparaison vendor ; sinon abandon |
| Horloge HCODEC absente du CCF (§4.3) | moyenne | encode lent ou pendu | s'appuyer sur `vdec_1` ; sinon patch CCF local |
| CAVLC seulement → qualité à bas débit | **certaine** | NVR dégradé | PSNR/débit contre x264 avant toute promesse |
| Registres DOS partagés (§4.8) | moyenne | corruption en transcode | verrou ou exclusion mutuelle ; mesurer en P3 |
| Code 100 % IA, 1 carte, pas upstream | certaine | dette | revue + non-régression à chaque bump noyau |
| Microcode non redistribuable | certaine | packaging | paquet séparé, `requireFile` si besoin |

**Abandon si** : (1) pas de `/dev/video*` après 1 j de P1 ; (2) aucune frame
décodable après 2 j de P2, ou pendaison du VPU qui emporte le décodage ; (3) à
débit égal en 1080p30, PSNR inférieur de plus de 2 dB à x264 `veryfast` ;
(4) régression du décodage stateless qualifié.

## 8. Questions ouvertes

1. **`AO_RTI_PWR_CNTL_REG0`** : le GXL a-t-il besoin de `& ~0x18` avant la mise
   sous tension du HCODEC, et quel est l'offset AO exact ?
2. **Horloge HCODEC** : quelle horloge alimente le bloc sur GXL, et `vdec_1`
   (activée par `amvdec`) suffit-elle ? À trancher par `clk_summary` et par
   l'essai, pas par lecture de code.
3. **Usage** : CAVLC 1080p60 suffit-il (transcode NVR, capture), ou faut-il du
   CABAC — c'est-à-dire une autre génération de SoC ? Si CABAC est requis, le
   port GXL est sans objet.

Secondaires : exposer aussi le JPEG (`gxl_jpeg_enc.bin`, 16 KiB, même PACK) ?
Embarquer le CLI chardev, ou seulement la façade V4L2 M2M ?

## 9. Sources

- Driver : `ray38080289/meson-sm1-codecs` @ `eb7a4446` —
  `venc-h264/{encoder.c,encoder.h,compat.c,compat.h,venc_v4l2.c,venc.c}`.
- Vendor : `pannal/media_modules-aml` `amlogic-4.9.269`
  (`frame_sink/encoder/{h264/encoder.c,jpeg/jpegenc.c}`) ; `CoreELEC/linux-amlogic`
  `amlogic-4.9-20` (`arch/arm64/boot/dts/amlogic/gxl_p212_2g.dts`).
- Noyau 7.0.14 : `meson-gx.dtsi`, `meson-gxl.dtsi`, `drivers/clk/meson/gxbb.c`,
  `drivers/staging/media/meson/vdec/{vdec_1.c,dos_regs.h}`,
  `drivers/pmdomain/amlogic/meson-ee-pwrc.c`, `kernel/dma/{direct.c,mapping.c}`,
  `drivers/soc/amlogic/meson-canvas.c` ; couche : `amlogic-0119-…patch`,
  `modules/family/meson64.nix`, `parts/modules.nix:124,136-140`,
  `modules/system/vdec-firmware.nix`.
- Firmware : `firmware/h264_enc.bin` (76 288 o, PACK KCAP) et
  `firmware/video_ucode.bin` des deux dépôts ci-dessus. Extraction par le même
  analyseur que `get-firmware.py` (`pack_entries()`) → **24 576 o**,
  md5 `548df08288d7cf48d4bb1255bca45ca7`,
  sha256 `edc596f81d0ff334595ed84172c5cce92769d0572999f1f735c0ef6269a909f6`.
  Identique dans les deux dépôts et **octet pour octet identique à
  `txl_h264_enc_cavlc.bin`** : un seul ucode CAVLC sert GXL et TXL. Absent de
  `linux-firmware` et de `LibreELEC/meson-firmware` (décodage seulement).
- Matériel : *S905L Quick Reference Manual* (juin 2016), relayé par
  `cnx-software.com/2016/09/20/amlogic-s905l-processor-drops-vp9-codec-ts-inputs-for-tuners-and-the-camera-interface/`
  et `androidtvbox.eu/amlogic-s905l-new-cheap-soc-amlogic` ;
  `wiki.postmarketos.org/wiki/Amlogic_S912` (S905L = S905X sans VP9/caméra/TS) ;
  `docs/boards/magicsee-n5.md` (SoC `0x21`, 2 GiB, mesuré) ;
  `docs/note-integration-meson-sm1-codecs.md`, `docs/etude-meson64.md`.
