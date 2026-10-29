# Travaux restants — état au 2026-10-28

> Ce qui est qualifié, ce qui manque, dans quel ordre, et ce qui peut être mené
> en parallèle sans se battre pour la machine. Les mesures et les causes sont
> dans `docs/diagnostics/` ; cette note ne fait que planifier.

## 1. Qualifié — ne pas refaire

- Boot NixOS 26.05 sur S905L via le U-Boot vendor (image SD, console `ttyAML0`).
- VPU stateless `meson-amvdec` : H.264, HEVC et VP9 **bit-exacts** en CLI,
  MPEG-2 correct (PSNR 68 dB) mais plus lent que le logiciel.
- Kodi en kiosque : GBM, lima en 1080p60, `CDVDVideoCodecDRMPRIME` actif,
  `/dev/video0` tenu pendant la lecture, zéro erreur.
- HDMI : EDID 256 octets, détection réelle (le câble était la cause du silence).
- Réseau : lien direct et SSH de qualification (`lab-ssh`, non versionné).
- **WiFi QCA9377 complet** (2026-10-28) : `ath10k_sdio` chargé, firmware
  `WLAN.TF.1.1.1-00061-QCATFSWPZ-1`, association 2,4 GHz, **IPv4 par DHCP**
  (`192.168.1.21/24`, `proto dhcp`), IPv6 SLAAC, ping passerelle 0 % de perte.
- **Débit WiFi mesuré** (hôte lui aussi en WiFi, donc plancher) : 38,6 Mbps en
  réception, 14,9 Mbps en émission. Suffisant pour du 1080p H.264.
- **Audio HDMI** (2026-10-29) : l'AIU n'expose qu'un PCM applicatif et
  aiguille ensuite vers le HDMI, l'ACODEC ou le SPDIF par le sélecteur
  `AIU HDMI CTRL SRC`, qui vaut `DISABLED` au boot — tout partait donc vers
  l'analogique. Sur `I2S`, le son sort. La rétractation du 2026-10-28 est
  levée ; voir B3 et `docs/diagnostics/n5-audio-hdmi-2026-10-29.md`.
- **CEC** : `meson-ao-cec` obtient l'**adresse physique `2.0.0.0`** de la TV
  (entrée HDMI 2) et une adresse logique — la poignée de main CEC fonctionne.
  Reste l'usage fonctionnel (télécommande du téléviseur).

## 2. Manques

### A. Reproductibilité — bloquant, avant tout le reste

| # | manque | preuve du défaut | coût |
|---|---|---|---|
| A1 | ~~branche non poussée~~ — **fait le 2026-10-28** | publiée sur `zibaone/nixbian` branche `feat/meson64-vdec-7.0`, commit `d83bbf83`, rejoué sur l'historique public (`public-sync`) et non poussé depuis l'arbre privé : le commit « retirer le `schedule:` mort de kernel-cache sur le privé » n'est pas publié, il ne concerne que la CI privée. Les 12 fichiers du commit vdec passent (patchs `amlogic-0118..0128`, `series.conf`, `overrides.json`, `platform_patches.json`). | fait |
| A2 | ~~`flake.lock` sur l'ancien rev~~ — **fait le 2026-10-28** | input pointé sur `github:zibaone/nixbian/feat/meson64-vdec-7.0`, lock sur `d83bbf83`. Plus besoin de `--override-input`, l'avertissement a disparu, et l'éval du dépôt voit bien les **7** patchs amvdec. Contrôle de fidélité : les deux arbres source (`path:` local vs `git` public) sont identiques fichier par fichier ; seul `.git` diffère, ce qui explique un `drvPath` distinct sans différence de contenu. | fait |

### B. Fonctions absentes ou non validées

| # | manque | état mesuré | coût | lane |
|---|---|---|---|---|
| B1 | **WiFi QCA9377** — *cause identifiée, correctif appliqué* | l'arbre de modules subit un élagage **deny-by-default** (`prune_modules.py` : socle par préfixe + alias `of:` du DTB + liste `--keep`). `drivers/net/wireless/` n'est ni dans le socle ni dans la liste, et le QCA9377 est un périphérique **SDIO** : son alias `sdio:c*v0271d0701*` n'est jamais lu (seuls les `of:` le sont), et le DTB p212 déclare `mmc@70000/wifi@1` **sans `compatible`**. 4450 modules compilés → 1723 conservés. Le `modules.order` recopié verbatim fait croire à tort que le module est là. | `ath10k_sdio` ajouté à `extraKeep` (fermeture : ath10k_core, mac80211, cfg80211, ath, rfkill, libarc4). **Validé le 2026-10-28** : `wlan0` apparaît, firmware `WLAN.TF.1.1.1-00061-QCATFSWPZ-1` chargé, `rfkill` voit `phy0`. Reste : l'image n'embarque **aucun supplicant** (`wpa_supplicant`/`iw` ajoutés depuis). Le message `failed to fetch board data … board-2.bin` suivi de `board_file api 1 crc32 544289f7` est le comportement **normal** de ce chip en mainline : `board-2.bin` ne contient que 37 entrées `bus=pci` et zéro `bus=sdio`, et le fichier d'`armbian/firmware` fait exactement la même taille (304 308 o) — il n'apporte rien. Le repli sur `board.bin` fonctionne (confirmé sur la liste ath10k par l'auteur LibreELEC). Un board file propre à la carte ne peut venir que du firmware vendor Android. | **validé sur carte** : association, IPv4 DHCP, IPv6, débit 38,6/14,9 Mbps |
| B2 | **télécommande IR** | `rc0` actif (`meson_ir` conservé par l'élagage), mais protocole `[lirc]` brut et aucune keymap. **Deuxième effet du même élagage** : les décodeurs rc-core (`ir-nec-decoder`…) n'ont aucun compatible OF et disparaissaient aussi — `ir_nec_decoder` est maintenant dans `extraKeep` | reste : activer `nec` + une keymap correspondant à la télécommande (30 min, après identification) | carte |
| B3 | **audio HDMI — résolu** (2026-10-29) | Ce n'était ni un module manquant ni un ordre de sonde : `gx-card` ne crée un PCM que pour les DAI dont le nom contient « FIFO », donc **un seul PCM est le comportement normal** ; le HDMI est un back-end (`dai-link-2`). Tout était en place — `eld#2` identifie la TV (SAMSUNG, 6 SAD), `i2s-hifi` est enregistré, les widgets `AIU HDMI I2S IN` / `HDMITX I2S Playback` / `HDMITX TX` sont `On` pendant la lecture, PCM `RUNNING` en `S24_LE` 48 kHz. Le flux était détourné par `AIU HDMI CTRL SRC` (numid 14), à `DISABLED` ; `PCM` (1) ne donne rien, **`I2S` (2) donne le son**. Le `softdep` tenté la veille n'avait aucun effet et a été retiré. | corrigé par `systemd.services.meson-hdmi-audio-route` dans `modules/family/meson64.nix` ; **validé le 2026-10-29** après démarrage à froid : service `success`, sélecteur à `I2S` sans intervention, 440 Hz entendu | — |
| B4 | **CEC** — *lien validé, usage fonctionnel non* | `cec-ctl -S` le 2026-10-28 : pilote `meson-ao-cec` 7.0.14, capacités `Logical Addresses / Transmit / Passthrough / Connector Info`, **adresse physique `2.0.0.0`** obtenue de la TV, adresse logique `0x2`. La poignée de main CEC fonctionne ; il reste à faire piloter Kodi par la télécommande du téléviseur | 2–3 h, config Kodi + test TV | board + code |
| B5 | **HEVC 4K — résolu** (2026-10-29) | 3840×2160 HEVC décodé par le VPU, **bit-exact** (`88cd8f3c…` identique au logiciel sur 10 images) et lu sans saccade dans Kodi (`CDVDVideoCodecDRMPRIME`, GUI 1080p60, 0,55 cœur de CPU sur 15 s). **Piège de mesure** : `-benchmark` en CLI donne 8,4 i/s, non pas à cause du VPU mais parce que la pipeline ramène chaque image 4K en mémoire système (~3 Go de copies) ; le rendu Kodi est en zéro-copie. La CMA de 256 Mio suffit (`CmaFree` encore 251 Mio après décodage). | — | — |
| B6 | **suspend / thermique** | jamais testés ; GXL throttlé au-delà de ~80 °C. **Placé après l'unification HavenOS** (décision du 2026-10-29) : pas de sens à qualifier une image qui change de dépôt | 2 h | board |
| B7 | **kiosque en 576p si la TV est en veille au boot** | `video=HDMI-A-1:1920x1080@60` ne s'applique que si le connecteur est détecté **au démarrage** : TV en standby ⇒ pas d'EDID ⇒ repli `720x576@50`, et **ça ne se rattrape pas à chaud** (re-détection par `echo detect` sur `card0-HDMI-A-1/status` puis redémarrage de Kodi : toujours 576p ; seul un reboot TV allumée restaure le 1080p). Constaté le 2026-10-29 pendant le test 4K. | à corriger : re-probe du connecteur sur hotplug (règle udev + redémarrage de Kodi) ou ne plus forcer le mode et laisser Kodi choisir | board + code |

### C. Dettes de code

| # | dette | coût | lane |
|---|---|---|---|
| C1 | `kodi` → `kodi-kiosk` (parité de fermeture avec sunxi64) | 30 min + build | build |
| C2 | couche kiosque neutre — **plan établi, 5 commits sur 4 dépôts** : C1 créer `nixelec-kiosk` (copie verbatim + le XML CEC qui voyage avec le module), C2 ré-export depuis `nixelec-sunxi64` (aucune rupture), C3 `HavenOS` (import + `wifi-uwe5622` conditionnel + **réinjecter les overlays `v4l2request`**, sinon −149 Mio de trim et chemins de store différents), C4 `nixelec-meson64` (supprimer le doublon en conservant `vdecFirmware`, `hardware.graphics`, `video=`, getty), C5 hôte N5 dans HavenOS — **fait le 2026-10-29** : `nixelec-kiosk` créé, cartes kiosk-free, hôte N5 dans la flotte ; l'input `nixelec-kiosk` a été retiré depuis (le kiosque n'est consommé que par HavenOS) | 1 j | fait (`4505279`) |
| C3 | routage MPEG-2 vers le logiciel dans Kodi (le VPU est plus lent) | 1 h de config | papier |
| C4 | `docs/branches.md` et les statuts de README à réaligner sur les mesures | 30 min | papier |

### D. Risques de fond

| # | risque | coût |
|---|---|---|
| D1 | HEVC `EXT_SPS_ST_RPS` absent de la série FFmpeg 6.1.6 | **chiffré : ≈ 9 h (7–13) de rebase** vers 7.1.5, dont 4 h de vraie API HEVC (`HEVCParamSets` perd `ps.pps/sps`, `h->ref` → `cur_frame`, DPB par couche), **plus le blocage Kodi** : le pin ne contient que Kodi 21.3, construit contre `libavcodec 60` → il faudrait un Kodi 22 vendorisé. **Verdict : ne pas y aller.** Le contrôle existe déjà côté noyau ; seul l'émetteur manque côté FFmpeg, et `ShortTermRPS` de 6.1 porte déjà tous les champs nécessaires : ~60–120 lignes, **3–5 h**, sans bump ni Kodi. À déclencher seulement si un flux l'exige. |
| D2 | plancher CPU du VPU : trafic mémoire (3,1 Mio/image, DMA non cohérent, pas d'IOMMU sur GXL), 0,83 × temps réel à 1080p | non prioritaire, gain attendu < 20 %, effort élevé |

## 3. Trois lanes, une règle chacune

| lane | contenu | règle |
|---|---|---|
| **build** | tout `nix build` (noyau, image, Kodi) | **un seul à la fois** : deux builds simultanés se partagent `max-jobs`, expirent et ralentissent le premier |
| **board** | toute expérience sur la carte | **une seule à la fois** : il n'y a qu'un boîtier, et un reboot invalide l'état des autres essais |
| **papier** | refactor, docs, CI, keymaps, études d'impact | illimitée : aucun conflit machine |

## 4. Vagues

**Vague 1 — parallèle, sans build ni carte**
B2 (préparer la keymap, en attente de l'identification de la télécommande) · D1 (étude d'impact du rebase FFmpeg 7.x, sans compiler) · B7 (le correctif du mode d'affichage se conçoit sans le boîtier).

**Vague 2 — la couche kiosque d'abord**
C2 (migration vers HavenOS : 3 dépôts, commits séparés). C'est le prérequis du reste : inutile de qualifier un boîtier sur une image qui va changer de dépôt.

**Vague 3 — après l'unification HavenOS**
B6 (thermique ~40 min ; suspend : à clore par une mesure négative assumée) · B4 (CEC) · installation eMMC · C1/C3 (finitions).

## 5. Découpage en subagents

**Sûr en parallèle** — contexte isolé, aucune ressource partagée : audits de code
et d'options, rédaction de notes, préparation de keymaps IR, étude d'impact d'un
rebase, revue de configuration CI, inventaire des écarts doc↔mesures.

**À ne jamais paralléliser** — `nix build` (store + `max-jobs`), accès à la
carte (un seul boîtier), réécriture simultanée des mêmes fichiers.

**Règle de sortie** : chaque subagent rend un artefact vérifiable — chemin de
fichier, diff, commande reproductible. Un « c'est fait » sans preuve ne se
vérifie pas, et un rapport de subagent est un témoignage, pas une mesure : ce
qui touche un dépôt ou la carte se revalide ici avant d'être annoncé.

## 6. Corrections apportées aux documents d'architecture

L'étude de la migration a relevé trois affirmations fausses dans la décision
`couche-kiosque-neutre.md`, corrigées sur place :

1. **« Trois plateformes font déjà tourner le même profil »** — faux pour le N5 :
   `nixelec-meson64` n'importe pas `kodi-standalone.nix` et utilise son propre
   `modules/system/kodi.nix`. Le profil ne tourne que sur `n150-kodi` et
   `orangepizero3-edge-kodi`.
2. **« `kodi-gbm.nix` : aucune référence SoC hors commentaires »** — faux en
   code : `boot.kernelModules = [ "dw-hdmi-cec" ]`, `card0-HDMI-A-1` par défaut,
   `/dev/cec0`, watchdog calibré sur `sunxi-wdt`. La couche n'est pas neutre,
   elle est **dw-hdmi**. Sur meson64 le pilote CEC s'appelle `cec-meson-ao` :
   la migration doit **paramétrer** le CEC (option), pas seulement déplacer le
   fichier.
3. **« 111 lignes »** pour le module meson64 — 125.

Conséquence sur le plan : C1 n'est pas une copie pure, c'est une copie **plus
une mise en option du pilote CEC**. Le critère d'acceptation « grep SoC vide »
devient donc atteignable, mais il exige ce travail.
