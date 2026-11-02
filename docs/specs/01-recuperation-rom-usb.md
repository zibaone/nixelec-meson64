# Spec 01 — Récupération par USB depuis le ROM (Amlogic GXL)

| | |
|---|---|
| Statut | **brouillon**, non commencé |
| Portée | Magicsee N5 (S905L, ROM 0.7 / stage 0.16), réutilisable sur GXL |
| Dépend de | le BL33 mainline étant écrit — c'est le rôle de `/etc/n5/uboot-install.sh` et de la branche mainline de l'installateur (`docs/specs/03-installateur-deux-schemas.md`) ; tant que le vendor est en place, la porte `run update` existe encore |
| Non-buts | le chemin SD, le dongle HDMI, le contournement de secure boot |

## Problème mesuré

Une fois le BL33 vendor remplacé, le seul chargeur restant est le ROM. Or il
n'existe aujourd'hui **aucun outil capable de lui parler** :

| tentative | résultat |
|---|---|
| `pyamlboot` `write 0x11` (BL2 49 152 o + params) | accepté |
| `pyamlboot` `run 0x05` | `Errno 5`, puis le périphérique **se déconnecte** |
| `update` (osmc/aml-flash-tool, patché pour NixOS) `chipid` | `This firmware version is 0-7-0-16` puis `romStage not bl1/bl2, cannot support chipid` |
| `update` `identify 7`, `mread`, `bulkcmd` | `get cbw failed` / timeouts |
| `update` `bl2_boot` depuis un U-Boot vendor vivant | `USBErr:568--unknown vendor req 40.50` |

Le ROM se laisse identifier (`socid` → `ROM: 0.7 Stage: 0.16`, `Need Password: 0`)
mais refuse tout chargement. La même boîte, **avec** son U-Boot vendor, accepte
tout : `run update` → `InUsbBurn`, `[MSG]sof`, `Get DT cfg`, puis
`mread store bootloader` (1 Mio lu) et `partition bootloader` (`mwrite success`).

La différence n'est pas le câble : c'est le **handler**. Le U-Boot vendor
implémente `0x50`/`0x60` (AMLC/FIP), le ROM 2019 attend le même flux AMLC et
nos deux outils ne le produisent pas (pyamlboot est resté au vieux couple
« BL2 à 0xd9000000 + jump » `0x11`/`0x05`).

## Ce qu'on sait du protocole

- Constantes relevées dans `update` : `Platform:0x0811`,
  `DDRLoad/DDRRun 0xd9000000`, `UbootLoad 0x200c000`,
  `bl2ParaAddr 0xd900c000`, `Control0 = 0xd9000000:0xb1`,
  `Control1 = 0xd9000000:0x5183`, `Encrypt_reg 0xc8100228`.
- Transferts de contrôle de `update` : `mov $0x50,%edx` et `mov $0x60,%edx`
  (là où pyamlboot fait `0x01`/`0x11`) ; chaînes `AMLS`,
  `[LUSB]BL2 END, waiting TPL plug-in`, `password`, `bl2_boot`.
- Le FIP est un conteneur à en-tête de 0x100 octets (`@AML` à 0x10, tailles,
  SHA256) suivi des BL — format que nous savons déjà assembler et découper
  (`gxlimg`).
- `Need Password: 0` : la carte n'est pas verrouillée, ce n'est pas un problème
  de signature.

## Décision : deux routes, dans cet ordre

### Route A — sonder la garde de stage de `update` (1 à 2 h)

`update` **contient déjà** l'implémentation AMLC ; il refuse uniquement parce
qu'il teste le stage du ROM (`bl1`/`bl2`). C'est un branchement, pas une
réécriture.

1. localiser la comparaison qui produit `romStage not bl1/bl2` (référence :
   la chaîne dans le binaire, puis remonter au test) ;
2. patcher le branchement pour qu'il poursuive quel que soit le stage ;
3. sur la boîte en ROM : `identify`, `mread` (lecture seule d'abord), puis
   `partition` seulement si la lecture rend un FIP valide.

**Localisation faite (2026-11-01).** `tools/update-x86` est un ELF x86-64
**non strippé**, d'où la lecture directe :

| élément | valeur |
|---|---|
| fonction | `update_sub_cmd_get_chipid` @ `0x40b3e9` |
| chaîne | `romStage not bl1/bl2, cannot support chipid` @ `0x4229b0` |
| test | octet de stage lu dans la réponse `identify`, accepté s'il vaut `0` ou `8` |
| refus | `aml_printf` puis retour `-0x357` (`0xfffffca9`) |
| patch | fichier offset **`0xD4A6`** : `74 36` (`je`) → `EB 36` (`jmp`) |

Un seul octet suffit : la branche « stage accepté » est prise
inconditionnellement. Vérification par désassemblage après patch :
`40b4a6: eb 36  jmp 40b4de`.

Notre ROM annonce **0.16**, soit l'octet 16 : il tombe précisément dans le trou
entre les deux valeurs acceptées. Copie patchée de travail :
`~/.hermes/profiles/havenos/cache/scratch/update-x86-patched`.

Réserve : ce patch lève un **garde**, il n'ajoute pas de protocole. Si le stage
0.16 ne connaît pas les commandes suivantes, l'échec se déplacera plus loin —
c'est justement l'information recherchée.

Sortie : soit la porte ROM existe avec l'outil vendor (et la route B devient une
réécriture propre, avec une référence qui marche), soit le refus vient d'ailleurs
et on documente ce qui manque avant de forker.

### Route B — fork pyamlboot : implémenter AMLC (si A ne suffit pas)

- cible : `nixelec-meson64/pkgs/`, un outil distinct plutôt qu'un patch de
  pyamlboot (la CLI de pyamlboot est un script Python, l'AMLC est du bulk
  binaire) ;
- ordre imposé : **identifier → relire → écrire**. Aucune écriture tant que la
  lecture d'un FIP connu ne rend pas les bons SHA256 ;
- réutilisation : `gxlimg -t fip` pour fabriquer le conteneur, la même
  vérification `cmp` que l'installateur.

## Plan

| # | tâche | sortie vérifiable |
|---|---|---|
| A1 | brancher l'UART + `lsusb` (attendre `1b8e:c003`) | identifiant lu par `socid` |
| A2 | localiser et patcher la garde de stage de `update` | `chipid` ne rend plus `romStage not bl1/b2` |
| A3 | `mread store bootloader` depuis le ROM | 1 Mio et SHA256 reconnu (dump de référence) |
| A4 | si A3 passe : `partition bootloader` d'un FIP déjà validé | boot complet |
| B1 | si A3 échoue : relever la séquence AMLC (trace USB) et l'écrire | rejeu hors ligne |
| B2 | outil + tests sur données simulées | lecture/écriture cohérentes |
| B3 | essai sur une unité au FIP eMMC invalidé | récupération complète |

## Risques

- **Écrire un FIP faux** : l'unité retombe en ROM. Parade : la lecture (A3)
  doit passer avant l'écriture, et le FIP écrit doit être celui déjà validé.
- **Le ROM exige un conteneur signé** : `Need Password: 0` rend l'hypothèse peu
  probable, mais seul A3 tranche.
- **Temps** : la séquence AMLC n'est pas documentée publiquement ; sans la
  référence `update`, c'est du reverse pur (plusieurs sessions, résultat
  incertain).

## Critères de sortie

1. une unité dont le FIP eMMC est illisible redémarre **sans SD ni dongle** ;
2. l'outil relit le FIP écrit et le compare à la source ;
3. la procédure est dans `docs/specs/` **et** testée sur une unité sacrifiable.

## Ce qui invaliderait cette spec

- la carte SD à FIP se révèle systématiquement suffisante (aucun besoin de
  porte USB) ;
- le ROM s'avère exiger une signature (la route devient sans objet).
