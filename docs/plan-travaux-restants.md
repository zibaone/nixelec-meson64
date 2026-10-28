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

## 2. Manques

### A. Reproductibilité — bloquant, avant tout le reste

| # | manque | preuve du défaut | coût |
|---|---|---|---|
| A1 | branche `feat/meson64-vdec-7.0` non poussée sur `zibaone/nixbian` | toute image construite sans `--override-input nixbian path:…` perd le VPU **en silence** ; seul un `evaluation warning` l'annonce | 1 h + CI |
| A2 | `flake.lock` ne pointe pas cette branche | même effet pour tout consommateur du dépôt | 30 min, après A1 |

### B. Fonctions absentes ou non validées

| # | manque | état mesuré | coût | lane |
|---|---|---|---|---|
| B1 | **WiFi QCA9377** | SDIO `0271:0701` présent, `CONFIG_ATH10K_SDIO=m`, `modules.order` liste `ath10k_{core,pci,sdio,usb}.ko`, mais **`drivers/net/wireless/` absent de l'arbre installé** → `modprobe ath10k_sdio` : *Module not found* | 1 build de noyau (~50 min) ; si la reconstruction ne corrige pas, investigation de la phase `modules_install` | build |
| B2 | **télécommande IR** | `rc0` actif, `input0` en `kbd`/`event0`, mais protocole `[lirc]` brut et **aucune keymap** | 30 min, après identification de la télécommande | board |
| B3 | **audio HDMI** | carte ALSA `S905X-P212`, `pcmC0D0p` présente, **rien n'a jamais été écouté** | 1 h | board |
| B4 | **CEC** | `/dev/cec0` présent, Kodi ne l'exploite pas (télécommande du téléviseur) | 2–3 h, config Kodi + test TV | board + code |
| B5 | **HEVC 4K** | le VPU GXL décode l'HEVC 4K, **jamais testé** ; c'est la valeur du boîtier sur une TV 4K | 1 h | board |
| B6 | **suspend / thermique** | jamais testés ; GXL throttlé au-delà de ~80 °C | 2 h | board |

### C. Dettes de code

| # | dette | coût | lane |
|---|---|---|---|
| C1 | `kodi` → `kodi-kiosk` (parité de fermeture avec sunxi64) | 30 min + build | build |
| C2 | couche kiosque neutre : la décision est écrite, la migration fait 5 commits sur 3 dépôts | 1 j | papier + build |
| C3 | routage MPEG-2 vers le logiciel dans Kodi (le VPU est plus lent) | 1 h de config | papier |
| C4 | `docs/branches.md` et les statuts de README à réaligner sur les mesures | 30 min | papier |

### D. Risques de fond

| # | risque | coût |
|---|---|---|
| D1 | HEVC `EXT_SPS_ST_RPS` absent de la série FFmpeg 6.1.6 : certains flux broadcast exigeront FFmpeg 7.x (rebase des 4 patchs + rebuild Kodi) | 1–2 j |
| D2 | plancher CPU du VPU : trafic mémoire (3,1 Mio/image, DMA non cohérent, pas d'IOMMU sur GXL), 0,83 × temps réel à 1080p | non prioritaire, gain attendu < 20 %, effort élevé |

## 3. Trois lanes, une règle chacune

| lane | contenu | règle |
|---|---|---|
| **build** | tout `nix build` (noyau, image, Kodi) | **un seul à la fois** : deux builds simultanés se partagent `max-jobs`, expirent et ralentissent le premier |
| **board** | toute expérience sur la carte | **une seule à la fois** : il n'y a qu'un boîtier, et un reboot invalide l'état des autres essais |
| **papier** | refactor, docs, CI, keymaps, études d'impact | illimitée : aucun conflit machine |

## 4. Vagues

**Vague 1 — parallèle, sans build ni carte**
A1 (pousser la branche + CI) · C4 (realigner la doc) · B2 (préparer la keymap, en attente de l'identification de la télécommande) · D1 (étude d'impact du rebase FFmpeg 7.x, sans compiler).

**Vague 2 — un build + des tests carte, en parallèle l'un de l'autre**
B1 (build noyau, lane build) **pendant** B3 et B5 (tests audio et HEVC 4K, lane board). Les deux lanes ne se disputent rien : le build tourne en qemu, les tests sur le boîtier.

**Vague 3 — après validation des précédents**
C2 (migration de la couche kiosque : 3 dépôts, commits séparés) · B4 (CEC) · C1/C3 (finitions).

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
