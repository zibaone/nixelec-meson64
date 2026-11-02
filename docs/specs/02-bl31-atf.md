# Spec 02 — Remplacer le BL31 vendor par ATF (Amlogic GXL)

| | |
|---|---|
| Statut | **brouillon**, non commencé |
| Portée | Magicsee N5 (S905L, p212) ; le même FIP sert tout GXL |
| Dépend de | la chaîne FIP de l'installateur, **branche mainline** (`docs/specs/03-installateur-deux-schemas.md`, §1.8 de `docs/installateur.md`) ; la Spec 01 n'est utile qu'en cas d'échec d'écriture |
| Non-buts | remplacer BL2 et BL30 (restent des blobs vendor) |

## Problème

Le FIP de la carte contient un BL31 **vendor daté du 12/05/2017** (bannière
`BL31 v1.0 (2017-05-12)`), et le démarrage imprime à chaque fois :

```
ERROR:   Error initializing runtime service opteed_fast
```

Il annonce un OP-TEE absent. Ce n'est pas bloquant (SMP, PSCI et reset
fonctionnent), mais c'est le dernier étage remplaçable qui reste un blob non
reproductible : BL2 (DDR init) et BL30 (SCP) n'ont pas d'équivalent ouvert, BL31
si.

## Décision

Remplacer **uniquement** le BL31 par un build ATF upstream, assemblé par la même
chaîne que le BL33 (branche mainline de l'installateur,
`docs/specs/03-installateur-deux-schemas.md` ; détail de la chaîne dans
`docs/uboot-mainline.md`).
nixpkgs fournit déjà `armTrustedFirmwareS905` (**ATF 2.14**, plateforme
`meson`/gxbb qui couvre GXL).

## Design

1. dérivation Nix : partir de `armTrustedFirmwareS905`, forcer
   `MESON_PLATFORM=gxl` (à confirmer : la dérivation nixpkgs est nominalement
   gxbb) et `PRELOADED_BL33_BASE=0x01000000` (adresse de chargement du BL33,
   cf. `CONFIG_TEXT_BASE` du build p212) ;
2. produire `bl31.bin` et vérifier l'en-tête (ELF aarch64, point d'entrée) ;
3. assembler `gxlimg -t fip --bl2 <installé> --bl30 <installé> --bl31 <atf>
   --bl33 <mainline>` ;
4. contrôle avant écriture : ré-extraction et `cmp` de BL2/BL30/BL33 avec
   l'installé — **seul le BL31 doit différer** ;
5. écrire par la même chaîne que l'installateur (sauvegarde d'abord).

## Plan

| # | tâche | sortie vérifiable |
|---|---|---|
| 1 | dérivation ATF gxl | `bl31.bin` non vide, `file` = ELF 64-bit ARM |
| 2 | assemblage + `cmp` des composants | seul `bl31.enc` diffère |
| 3 | écriture sur une unité sacrifiable | boot jusqu'à l'invite |
| 4 | contrôles fonctionnels | `nproc` = 4, `reboot` propre, pas d'`opteed` |
| 5 | contrôles de non-régression | extlinux + génération courante, Kodi démarre |

## Risques

- **SCPI** : le BL30 vendor est en protocole « legacy pre-1.0 » (le noyau le
  journalise). ATF peut attendre ≥ 1.0 pour la découverte des domaines
  d'alimentation ; symptôme : panique ou `scpi` muet au démarrage.
- **PSCI suspend/resume** : non testé aujourd'hui ; un BL31 upstream peut
  changer le comportement de veille.
- **Écriture** : un FIP faux = ROM (Spec 01). Parade : sauvegarde + carte SD à
  FIP à portée de main.

## Critères de sortie

1. la carte démarre sans `opteed_fast` ;
2. SMP complet, `reboot` et `poweroff` propres ;
3. l'extlinux et le menu de générations fonctionnent comme avant ;
4. le FIP est reconstructible depuis le store (`gxlimg`, sans blob vendor pour
   le BL31).

## Effort et priorité

Une session (dont la moitié pour la dérivation). Priorité **basse** : le BL31
vendor fonctionne ; le gain est la reproductibilité et un message d'erreur en
moins. À faire quand BL2/BL30 deviendront le sujet, ou si l'on veut une chaîne
d'amorçage entièrement construite — ce qui n'arrivera pas tant que BL2 reste
signé par Amlogic.
