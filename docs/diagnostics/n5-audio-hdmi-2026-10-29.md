# N5 — audio HDMI muet : le sélecteur de source de l'AIU, relevé du 2026-10-29

> Image `magicsee-n5-kodi` (noyau 7.0.14, patchs `meson64-vdec-7.0`).
> **Résolu : `AIU HDMI CTRL SRC` valait `DISABLED` et devait être sur `I2S`.**
> Ce n'était ni un ordre de sonde, ni un module manquant, ni un défaut de DTS :
> toute la chaîne était en place et allumée, seul ce sélecteur de mixer
> détournait le flux vers l'ACODEC analogique.

## Le point de départ, y compris l'erreur

Le 2026-10-28, l'audio HDMI avait été déclaré validé sur la foi d'un PCM ALSA
en état `RUNNING` pendant la lecture d'un MP4. C'était faux et la mention a été
rétractée le même jour : `/proc/asound/pcm` ne listait que `fe.dai-link-0`,
c'est-à-dire l'ACODEC analogique, et `amixer -c 0 scontrols` ne rendait que des
contrôles `ACODEC*`. Un PCM qui tourne ne prouve rien sur la destination.

## Ce que la chaîne montrait, tout en vert

Trois accusations ont été instruites puis écartées par la mesure :

| hypothèse | vérification | verdict |
|---|---|---|
| module HDMI absent du noyau | `/proc/config.gz` : `SND_SOC_HDMI_CODEC=m`, `DRM_DW_HDMI_I2S_AUDIO=m`, `SND_MESON_GX_SOUND_CARD=m` | écartée |
| ordre de sonde (carte avant codec) | `softdep` posé, **ordre de chargement inchangé** ; `modprobe --show-depends` ne liste pas le softdep | écartée |
| DTS incomplet | DTB vivant : `hdmi-tx@c883a000` a `#sound-dai-cells = <0x00>`, `sound-name-prefix = "HDMITX"`, `status = "okay"` | écartée |

Et pourtant côté noyau, tout était déjà correct :

```
$ cat /proc/asound/card0/eld#2
monitor_name        SAMSUNG
connection_type     HDMI
sad_count           6            # LPCM 2ch et 6ch, 32 à 192 kHz
```

```
$ cat /sys/kernel/debug/asoc/dais
... CODEC CTRL HDMI I2S IN / CODEC CTRL HDMI OUT / i2s-hifi   # le codec HDMI est là
```

```
$ cat /sys/kernel/debug/asoc/S905X-P212/hdmi-audio-codec.2.auto/dapm/*
AIU HDMI I2S IN Playback: On  in 1 out 1
HDMITX I2S Playback:      On  in 1 out 1
HDMITX TX:                On  in 1 out 1
```

PCM `RUNNING`, `S24_LE`, 2 canaux, 48 000 Hz, graphe DAPM alimenté de bout en
bout — et toujours aucun son. Le diagnostic « ça ne sort pas du noyau » était
donc faux : le flux arrivait bien au bloc HDMI.

## La mesure qui tranche

```
$ amixer -c 0 contents | grep -A5 "AIU HDMI CTRL SRC"
numid=14,iface=MIXER,name='AIU HDMI CTRL SRC'
  ; type=ENUMERATED,access=rw------,values=1,items=3
  ; Item #0 'DISABLED'
  ; Item #1 'PCM'
  ; Item #2 'I2S'
  : values=0
```

Sur ce SoC, l'AIU n'expose **qu'un seul PCM applicatif** : il aiguille ensuite
le flux vers le HDMI, l'ACODEC ou le SPDIF par ce sélecteur. À `DISABLED`, rien
n'est routé vers le bloc HDMI, quel que soit l'état du graphe DAPM en aval.

Le front-end du DTS p212 est `CPU_I2S_FIFO`, donc la source correcte est
**`I2S`**, pas `PCM` :

| valeur | résultat |
|---|---|
| `DISABLED` (0) | muet — état d'usine |
| `PCM` (1) | **muet aussi** (testé) |
| `I2S` (2) | **son audible** |

`PCM` avait été essayé d'abord, par analogie avec un flux PCM brut : c'est un
piège, l'encodeur I2S est dans le chemin.

## Le correctif

Un service `oneshot` qui pose le sélecteur avant le démarrage de Kodi, dans
`modules/family/meson64.nix` :

```nix
systemd.services.meson-hdmi-audio-route = {
  description = "Router le PCM de l'AIU vers le bloc HDMI";
  wantedBy = [ "multi-user.target" ];
  after = [ "sound.target" ];
  before = [ "kodi.service" ];
  serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
  script = ''
    i=0
    while [ "$i" -lt 20 ]; do
      ${pkgs.alsa-utils}/bin/amixer -c 0 cset name='AIU HDMI CTRL SRC' I2S && exit 0
      i=$((i + 1))
      sleep 0.5
    done
    echo "AIU HDMI CTRL SRC introuvable : routage HDMI non appliqué" >&2
    exit 1
  '';
};
```

La boucle est bornée parce que la carte peut apparaître après le démarrage du
service. L'état du mixer n'est pas persistant d'un boot à l'autre : sans ce
service, tout retour à `DISABLED` au redémarrage.

Le `softdep snd_soc_meson_gx_sound_card pre: snd_soc_hdmi_codec …` du
2026-10-28 a été **retiré** : il n'avait aucun effet mesurable et il aurait
laissé croire à une cause d'ordre de sonde.

## Ce que `log_buf_len=2M` a appris

Rien, et c'est une information : avec un tampon de 2 Mio, `dmesg` ne contient
**aucun** message ASoC. Le pilote `gx-card` ne journalise pas une sonde
réussie, et il n'y avait aucune erreur à voir. L'image de diagnostic a donc
servi à écarter la piste « erreur noyau invisible », pas à trouver la cause —
la cause était dans l'état du mixer, pas dans le journal.

## Vérifier après un démarrage à froid

```bash
systemctl status meson-hdmi-audio-route        # doit être active (exited)
amixer -c 0 contents | grep -A5 "AIU HDMI CTRL SRC" | tail -1   # : values=2
```

Puis lecture d'un fichier avec piste audio : le son doit sortir **sans**
intervention manuelle. Fait le 2026-10-29 sur l'image `1fb9icgh…` : service `active (exited)`, `ExecMainStatus=0`, sélecteur à `values=2` dès le boot, et le 440 Hz audible **sans aucune intervention**.
