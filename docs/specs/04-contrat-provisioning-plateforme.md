# Spec 04 — Provisioning : contrat de plateforme

| | |
|---|---|
| Statut | **proposée** — contrat à arbitrer. Le volet `meson64` décrit l'existant et le remplace sans changement de comportement ; le volet `sunxi64` (H618) est **mesuré** sur unité (2026-11-05), le provider reste à écrire |
| Portée | le contrat entre la mécanique d'installation (HavenOS) et les familles (`nixelec-meson64`, `nixelec-sunxi64`) : plan, layout, assets d'amorçage, vetos, inventaire et dump du chargeur |
| Dépend de | Spec 03 (deux schémas, `nixelec.bootloader`) ; C8/C10 (charge utile épinglée) |
| Non-buts | la mécanique d'installation elle-même (spec HavenOS `installateur-unifie`), le banc d'essai (spec HavenOS `banc-validation-plateforme`), le provisionnement des secrets (`havenos-provisioning`), le repartitionnement d'une unité en service |

## Problème mesuré

Deux mécaniques de provisioning coexistent et font la même tâche avec deux
implémentations :

| | `nixelec-meson64` `n5-install` (module 534 l.) | `HavenOS` `install.sh` (909 l.) |
|---|---|---|
| système installé | cible **bakée** (`target_system`) | **lui-même** (`/run/current-system`) |
| source de la clôture | store de l'installeur | `/boot` photographié, puis `nix copy` |
| layout | **`keep`** : p1/p2 doivent exister, refus de repartitionner | **`create`** : MBR neuve, p1 au secteur 1368064, 488 Mio |
| table de partitions | jamais réécrite | sauvegardée (`sfdisk --dump`), puis réécrite |
| sauvegarde | préfixe 668 Mio compressé + `boot0`/`boot1` | table seule |
| assets d'amorçage | générés depuis le store installé | copiés depuis `/boot` |
| FIP / BL33 | écrit (mainline), composants relus et comparés | jamais écrit |
| secrets | non | oui (unité `havenos-secrets`) |
| gardes | schéma, outil, EUID, disque, p1/p2, `1368064`, disque de boot, 64 Mio, `YES`, fstab, relecture | G1–G8 |

Conséquences mesurées :

- `1368064` (668 Mio) est **codé en dur dans les deux** scripts ;
- la charge utile (`uImage`, `uInitrd`, autoscripts, `uEnv.ini`) a **deux
  générateurs** : `n5-boot.nix`/`n5-install` d'un côté, la copie depuis `/boot`
  de l'autre ;
- l'étiquette de racine est **statique** dans le bootstrap (`NIXOS_SD`) alors
  que la cible kiosque est en `NIXOS_EMMC` — d'où un `e2label` manuel au
  passage bootstrap → kiosque ;
- la taille des images ne dépend pas de la plateforme mais du **fournisseur de
  système** (4,04 Gio baké, 1,44 Gio self, ~1,5 Gio distant) ;
- les deux scripts refusent d'écrire le secteur 1 sans l'avoir désigné, mais
  chacun avec sa propre logique.

## Décision

Quatre contrats, un seul moteur :

1. **le plan** — ce qu'on installe, écrit par la cible ;
2. **le provider plateforme** — comment le média s'amorce, fourni par la
   famille ;
3. **le fournisseur de système** — d'où vient la clôture (bakée, cache local,
   distante, ou soi-même) ;
4. **le moteur** — la mécanique d'installation, côté HavenOS.

### Le plan

```json
{
  "family": "meson64",
  "board": "magicsee-n5",
  "scheme": "vendor",
  "rootLabel": "NIXOS_EMMC",
  "system": "/nix/store/…-nixos-system-aml-s9xx-box-edge-kodi-vendor-…",
  "dtb": "amlogic/meson-gxl-s905x-p212.dtb",
  "layout": "keep",
  "bootMib": 488
}
```

Règles :

- `scheme` est **aussi baké dans l'image** ; l'installateur refuse un plan dont
  le schéma diffère (même refus qu'aujourd'hui, autre source). C'est le seul
  champ dont la valeur est une décision de sécurité : il décide de l'écriture du
  secteur 1.
- `system` est un **chemin de store** : content-addressed, non substituable. Un
  plan reçu ne peut pas changer le contenu d'un système, seulement en désigner
  un autre — risque résiduel « valide mais pas le bon », détectable par
  `init=`/nom d'hôte.
- `rootLabel` est confrontée au `fstab` installé avant de conclure (garde
  existante).
- `rootLabel` est **constante par cible**, jamais par schéma ni par média :
  `NIXOS_EMMC` pour le kiosque (vendor comme mainline), `NIXOS_SD` pour le
  bootstrap. Le moteur l'applique **au formatage** ; sur une unité déjà
  installée, seul un mode `relabel` explicite la change, et il exige que le
  `fstab` de la génération cible **et** le chargeur la désignent déjà.
- le plan peut être **épinglé** : `--plan-sha256 <digest>`, ou le digest baké
  avec le plan. Le moteur refuse un plan dont l'empreinte diffère, **avant tout
  accès au média**. Le digest couvre schéma, système, étiquette et layout d'un
  seul coup — inutile d'épingler le système séparément, ce qui rendrait le plan
  reçu sans objet.
- `layout` et `bootMib` viennent du provider, pas de l'opérateur.

### Le provider plateforme

Données :

| donnée | rôle |
|---|---|
| `protectUntil` | premier secteur libre après le chargeur (meson64 : 1368064) |
| `layout` | `keep` ou `create` |
| `bootMib` | taille de la FAT d'amorçage (488 Mio sur N5) |
| rôles | quelle partition porte la FAT, laquelle porte la racine |
| format des assets | payload épinglé, extlinux, FIP, boot0/u-boot |

Fonctions :

```
platform_tools_check      → outils de la branche, avant tout accès au média
platform_detect           → disque, partitions, offsets (lecture seule)
platform_guard            → vetos propres à la famille (offset du chargeur)
platform_backup_extra     → médias du chargeur (boot0/boot1 sur meson64)
platform_write_boot       → écrit la chaîne d'amorçage depuis le store installé
platform_verify_boot      → relit, compare, et dit si l'amorçage est prouvé
platform_write_bootloader → écrit le chargeur seul (migration, hors installation)
platform_inventory        → inventaire lecture seule : médias, chargeur, réseaux, contrat
platform_dump_loader      → dump borné du chargeur, DTB embarqué, environnement, hachés
```

Les deux premières précèdent la garde root (un outil manquant après
`nixos-install` laisserait une eMMC sans charge utile) ; `platform_guard` et
`platform_backup_extra` sont l'équivalent, côté famille, des gardes et de la
sauvegarde génériques du moteur.

Le moteur n'a le droit de connaître **aucun** offset, aucun outil, aucun nom de
fichier propre à une famille.

### Inventaire et dump : deux capacités, pas deux étapes du plan

`platform_detect` suffit au moteur, pas à l'opérateur : une unité dont on ignore
le chargeur ne peut être ni décrite ni sauvegardée avant écriture. D'où deux
fonctions, **hors pipeline** et **strictement en lecture** :

- `platform_inventory` rend un manifeste JSON — seul format consommé par les
  autres outils (installateur, banc, poste de travail). Champs : famille, board,
  DTB, hôtes MMC et mode, disques (modèle, taille, étiquettes, `boot0`/`boot1`),
  USB (masse, net), PHY réseau détectés et état du lien, chargeur en place (type,
  version, offsets de signature), contrat d'image.
- `platform_dump_loader` écrit des artefacts hors du média : zones de chargeur
  bornées, DTB embarqué extrait (et décompilé quand la famille sait le faire),
  environnement U-Boot s'il réside sur le média. Chaque artefact porte son
  offset, sa taille, son sha256 et sa provenance. Ouverture en lecture seule,
  taille bornée par défaut.

Ni l'une ni l'autre ne modifie un média : elles ne sont donc pas soumises aux
gardes G1–G8 et ne remplacent pas `platform_backup_extra`, qui sauvegarde *le
plan* (ce qui sera écrasé). `platform_dump_loader` décrit ce qui *est en place*,
y compris quand aucun plan n'est demandé.

Ce qui n'entre pas ici : le banc d'essai (`boot-test`, `net-test`, noyau à chaud).
Ce sont des consommateurs du même manifeste, pas des étapes de provisionnement —
les mêler au moteur réintroduirait des offsets de famille là où le contrat les
interdit.

### meson64 — ce que le provider doit reproduire

Le provider remplace `n5-install` sans changer un octet du comportement :

- **layout `keep`** : p1/p2 existants, `start(p1) ≥ 1368064`, refus de
  repartitionner ;
- **schéma vendor** : charge utile générée depuis le toplevel **installé**
  (`uImage`, `uInitrd`, DTB, `s905_autoscript` mmc 0, `emmc_autoscript` mmc 1,
  `uEnv.ini`, ni `boot.scr` ni conteneur multi), relecture hors cache et
  comparaison octet par octet, `init=` égal au profil `system` ;
- **schéma mainline** : `extlinux.conf` avec `LINUX`/`INITRD` vers
  `nixos/<génération>`, suppression de toute charge utile résiduelle, puis BL33
  dans le FIP — BL2/BL30/BL31 **extraits de l'unité**, candidat re-extrait et
  comparé, écriture, relecture et comparaison ;
- **`--no-bootloader`** (ex-`--no-bl33`) : mainline seulement ;
- **veto** : refus d'un plan `vendor` sur une unité dont le BL33 du FIP est
  celui du mainline connu (lecture seule, avant tout `dd`).

### sunxi64 (H618) — mesuré sur Transpeed 8K618-T (2026-11-05)

Connu : `nixelec-sunxi64/modules/image/sunxi-sd.nix` place U-Boot à **8 Kio**,
`populateFirmwareCommands = ""` (pas de partition firmware), et le dépôt n'a
**ni installateur ni option de schéma**.

Les six mesures qui bloquaient la phase 4 sont faites sur une unité réelle
(eMMC `CKTM4R` 58,2 Gio, `mmcblk1`) :

1. **Ordre de la ROM et offsets** : la ROM préfère la SD à la eMMC ; `boot0` et
   `boot1` sont vides (aucun octet non nul sur 4 Mio chacun), la zone utilisateur
   porte `eGON.BT0` à 8 196, avec copies de secours à 262 148 et 13 144 844.
   Conclure de l'absence de `boot0` que la eMMC n'est pas bootable serait faux :
   c'est la zone utilisateur qui amorce.
2. **Table de partitions** : `p1` FAT 30 Mio à 8 Mio, `p2` ext4 racine ensuite
   (défauts nixpkgs `sd-image`), étiquettes `FIRMWARE`/`nixos` ; rien d'Android à
   préserver sur cette unité, qui a été réécrite.
3. **Chargeur vendor vs mainline** : le mainline lit `extlinux.conf` sur `p2`
   (mesuré, `loglevel` modifiable in situ) ; le vendor Android n'a pas été testé
   — reste ouvert.
4. **`protectUntil`** : 8 192 + 792 313 o (`u-boot-sunxi-with-spl.bin`,
   `transpeed-8k618-t_defconfig` v2025.04) = 800 505 → **1 Mio** suffit, `p1` à
   8 Mio laisse 7 Mio de marge.
5. **Équivalent `--no-bootloader` et veto** : pas de FIP ; l'équivalent direct est
   de relire les 8 196 premiers octets avant écriture et de comparer la signature
   `eGON` et la version. `--no-bootloader` = ne pas écrire la zone SPL.
6. **eMMC vs NAND, DTB** : eMMC sur `mmc1`, pas de NAND ;
   `sun50i-h618-transpeed-8k618-t.dtb`.

Le provider sunxi64 n'est donc plus bloqué par des mesures. Ce qui reste à
trancher est du code, pas de l'inconnu : un chargeur en **deux étages** (SPL à
8 Kio puis U-Boot dans la même image) là où meson64 a un FIP, et l'absence de
partition firmware à remplir.

### Layout : les deux politiques existent déjà

`keep` (nixelec) et `create` (HavenOS, G5 + sauvegarde de table) sont **tous
deux implémentés**. L'unification doit les préserver, pas en ajouter une :

- `create` écrit une MBR neuve **mais jamais les secteurs 1 à `protectUntil`** ;
  la sauvegarde est la table seule, sauf si le FIP doit être écrit (alors le
  préfixe aussi) ;
- `keep` ne touche pas la table ; la sauvegarde du préfixe n'a de sens que si
  le FIP est écrit ;
- `create` sur une unité déjà installée est refusé par G5 si la p1 existante
  commence avant `protectUntil`.

## Tailles mesurées (meson64, 2026-11-02)

| | chemins | clôture | image brute | `.zst` |
|---|---|---|---|---|
| bootstrap (self) | 529 | 894 Mio | 1,44 Gio | 335 Mio |
| kiosque mainline | 843 | 2 560 Mio | — | — |
| kiosque vendor | 842 | 2 560 Mio | — | — |
| union des deux kiosques | 854 | 2 584 Mio | — | — |
| installeur avec cible | 987 | 2 865 Mio | 4,04 Gio | 926 Mio |

Partage bootstrap ↔ kiosque : 439 chemins, **725 Mio** communs. L'installeur
n'ajoute que **305 Mio** à la clôture du kiosque. Embarquer les deux cibles
coûte **+24 Mio** (l'initrd de chaque variante).

## Risques

- **Le chargeur H618 est en deux étages** (SPL à 8 Kio puis U-Boot dans la même
  image) là où meson64 écrit un FIP : c'est le cas que la spec prévoyait, et il
  se règle dans le provider, pas dans le moteur — la phase 4 le vérifiera.
- **`platform_dump_loader` peut aspirer des gigaoctets** si la borne par défaut
  n'est pas respectée : taille bornée obligatoire, et jamais sur un média monté
  en écriture.
- **Les artefacts de dump sont des blobs tiers** (chargeur vendor, NVRAM) : ils
  restent hors des dépôts publics, avec provenance et sha256 dans l'archive
  locale — seule exception documentée, la NVRAM déjà vendorisée dans
  `nixelec-sunxi64/modules/boards/firmware/`.
- **`create` est destructif par nature** : la garde G5 protège le préfixe, pas
  les partitions vendor au-delà. Sur une unité en service, `keep` doit rester le
  défaut du plan.
- **Le veto BL33 ne couvre que le binaire connu** : une unité migrée avec un
  autre build mainline ne sera pas détectée. Le refus reste asymétrique.

## Critères de sortie

1. le provider meson64 rend les **mêmes** scripts qu'aujourd'hui (diff nul après
   extraction) et les mêmes refus, vérifiés hors carte ;
2. le plan reçu avec schéma baké est refusé si le schéma diffère, avant tout
   accès au média ;
3. le provider sunxi64 s'écrit **sans modifier le moteur** — ou la spec est
   corrigée ;
4. aucun offset de famille ne subsiste dans le moteur (`grep 1368064` vide) ;
5. `platform_inventory` rend un manifeste aux **mêmes champs** sur meson64 et
   sunxi64, et ne fait aucune écriture sur le média ;
6. `platform_dump_loader` sort des artefacts bornés et hachés, et refuse un
   média monté en écriture.

## Ce qui invaliderait cette spec

- le plan lui-même doit changer pour le H618 (offsets non contigus, chargeur
  qu'on ne peut pas écrire d'un bloc) : le chargeur en deux étages est déjà
  couvert par le provider, un plan différent ne le serait pas ;
- HavenOS et nixelec divergent au point que deux moteurs restent nécessaires —
  la duplication est alors assumée et documentée, pas unifiée ;
- le cache binaire local rend le fournisseur de système inutile (une seule
  forme d'image suffit) : la spec se réduit au plan et au provider.
