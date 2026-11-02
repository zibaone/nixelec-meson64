# Spec 03 — Installateur eMMC : deux schémas d'amorçage

| | |
|---|---|
| Statut | **proposition**, non arbitrée |
| Portée | `modules/image/meson64-installer.nix`, `n5-boot.nix`, et la configuration de la cible ; N5 d'abord, réutilisable sur meson64 |
| Dépend de | le schéma **vendor** n'est vivable qu'avec la persistance de la charge utile (backlog C8 `havenos payload` + hook C10) ; le schéma **mainline** dépend de la chaîne FIP de l'installateur (§1.8 de `docs/installateur.md`) |
| Non-buts | remplacer BL31 (Spec 02), écrire le hook lui-même, la récupération ROM (Spec 01) |

## Problème mesuré

L'installateur a **silencieusement changé de schéma**. Le code du 2026-11-01
n'installe plus qu'une cible **mainline** :

| ce que fait `install.sh` | conséquence pour une cible vendor |
|---|---|
| exige `/mnt/n5/boot/extlinux/extlinux.conf`, s'arrête sinon | la cible vendor n'en écrit pas → installation interrompue après formatage |
| supprime `boot.scr` de p1 | plus d'entrée de boot pour le vendor |
| écrit le FIP/BL33 **inconditionnellement** | le chargeur vendor est remplacé même si on ne le voulait pas |
| ne génère **aucune** charge utile (`uImage`/`uInitrd`/autoscripts/`uEnv.ini`) | rien à charger pour un chargeur vendor |

Or cette image est aussi celle du **bootstrap** (C7) : une image sous 2 Gio qui
installe un système de bring-up sur une unité fraîche. Sur une unité fraîche, le
chargeur est vendor par définition — et le BL33 mainline n'a jamais été validé
sur une unité neuve : le binaire du dépôt est **reconstruit** (747 960 o) et non
celui validé à la main (794 448 o, même commit `3973f3c4d24d`, même
`p212_defconfig`, chaîne de compilation différente — `docs/installateur.md`
§1.8). Aujourd'hui, ce chemin ne peut donc pas aboutir : soit il s'arrête à
l'étape extlinux, soit il migre l'unité avant de l'avoir prouvée.

Mesures qui bornent le sujet :

- la N5 de référence tourne **U-Boot mainline 2027.01-rc1** (`/chosen/u-boot,version`),
  donc le schéma mainline est réel et c'est celui de la carte en service ;
- `/boot` **n'est pas monté** sur `NIXOS_BOOT` dans la configuration kiosque
  (`findmnt -T /boot` → `/`), donc `nixos-rebuild` n'écrit pas dans la FAT ;
  `extlinux.conf` sur la carte vient de l'installateur, pas d'une activation ;
- le vendor U-Boot lit `boot.scr`/`emmc_autoscript` et **pas** extlinux
  (`docs/amorcage-n5.md`).

## Décision proposée

L'installateur accepte **les deux schémas** et refuse tout mélange. Le
discriminant est l'état du **chargeur de l'unité**, pas la carte : la même N5
peut être vendor ou mainline.

1. **Option unique** : `nixelec.bootloader = "vendor" | "mainline"`, défaut
   `"mainline"` sur la N5 (mesuré), valeur posée par la configuration cible.
   Elle pilote trois choses, ensemble et pas séparément :
   - `boot.loader.generic-extlinux-compatible.enable` ;
   - le montage de `NIXOS_BOOT` sur `/boot` (nécessaire pour que `switch` écrive
     les générations — c'est ce qui manque aujourd'hui) ;
   - la forme de la charge utile (épinglée, ou aucune).
2. **`install.sh` prend le schéma** (`--vendor` / `--mainline`, ou lecture de
   `/etc/n5/scheme`) et **refuse** :
   - d'écrire un BL33 quand la cible est configurée `vendor` ;
   - de laisser une charge utile quand la cible est `mainline` (elle ne serait
     pas relue et masquerait l'absence d'extlinux).
3. **Branche vendor** — mêmes étapes 1 à 15 (sauvegarde, refus, formatage,
   `nixos-install`), puis :
   - générer la charge utile **du toplevel installé** sur p1 : copier
     `Image`/`initrd`/DTB depuis `/mnt/n5/nix/store`, `mkimage` pour
     `uImage`/`uInitrd`, écrire `s905_autoscript` (mmc 0) et `emmc_autoscript`
     (mmc 1) + `uEnv.ini` avec `init=<toplevel>/init` ;
   - ne **pas** écrire le BL33, ne pas exiger d'extlinux ;
   - vérifier par relecture que `uEnv.ini` et l'autoscript portent le **même**
     `init=`, égal au profil `system` de la cible.
4. **Branche mainline** — le comportement actuel (contrôle extlinux, suppression
   de `boot.scr`, écriture du BL33), avec l'écriture du BL33 rendue
   conditionnelle : `--no-bl33` pour une unité déjà migrée.
5. **La migration vendor → mainline reste hors de `install.sh`** :
   `/etc/n5/uboot-install.sh` (déjà présent) écrit le seul BL33 sans toucher aux
   partitions ; un `switch` ultérieur écrit extlinux (une fois `/boot` monté).
   Deux gestes séparés, réversibles, sur une carte déjà en service.

### Coût FAT, et pourquoi les deux branches diffèrent

| schéma | fichiers sur p1 | taille |
|---|---|---|
| vendor | `uImage` 36,6 Mo + `uInitrd` 24 Mo + DTB + 2 autoscripts + `uEnv.ini` | ≈ 61 Mo |
| mainline | `extlinux.conf` + `/nixos/<hash>/{Image,initrd,dtb}` × `configurationLimit` | ≈ 63 Mo par génération |

Les deux ne doivent pas cohabiter sur une carte : le vendor ne lirait que la
charge utile, et les générations extlinux mangeraient la place d'un fichier qu'il
lit (488 Mio de p1, `configurationLimit = 3`). Retirer au passage `uImage.multi`
(63 Mo) des cartes installées : il n'est plus produit (`594c4fe`).

## Design

```
components (n5-boot.nix) : mkBootFiles reste la source unique des deux formes
  ├─ artefacts épinglés : uImage, uInitrd, DTB, <media>_autoscript, uEnv.ini
  └─ artefacts extlinux : extlinux/extlinux.conf, Image, initrd, DTB

install.sh
  ├─ étapes communes : refus (1-7), sauvegarde (9-10), formatage (13-14),
  │                     nixos-install (16), contrôle d'étiquette (fstab)
  ├─ si mainline : extlinux présent ? (17) → bl33 (19-21, sauf --no-bl33)
  └─ si vendor   : charge utile générée sur p1 + vérif init= (17'-18')
```

Contraintes d'implémentation :

- **extlinux existe déjà dans l'arbre de travail** : `magicsee-n5.nix:83`
  (`enable = lib.mkDefault true`, `configurationLimit = 3`) et `meson64-sd.nix:30`
  (`mkForce false` sur le média de l'installateur, qui doit rester vendor).
  Ce n'est donc pas `enable` qui manque, c'est le **montage** : aucun
  `fileSystems."/boot"` n'existe dans `nixelec-meson64`. L'option de schéma doit
  porter les deux ensemble, sinon le commentaire du board (« `switch` maître de
  l'amorçage ») reste faux.
- **`ubootTools` doit entrer dans la fermeture de l'installateur** : la branche
  vendor appelle `mkimage` sur la carte. Il n'y est pas aujourd'hui
  (`environment.systemPackages` : `nixos-install-tools`, `dosfstools`,
  `e2fsprogs`, `util-linux`, `diffutils`, `zstd`, `gxlimg`).
- La charge utile vendor se génère depuis `/mnt/n5/nix/store` **après**
  `nixos-install` : c'est le seul moment où le toplevel cible et son noyau sont
  sur la cible.
- Le seuil de lecture FAT du vendor U-Boot (> 38 Mo illisible, mesuré) interdit
  de fusionner `uImage` et `uInitrd` : les deux fichiers séparés sont une
  contrainte du chargeur, pas un choix.
- `nixelec.rootLabel` (arbre de travail, non commité) doit être posé avant
  `mkfs.ext4` : une cible vendor sur `NIXOS_EMMC` et une SD sur `NIXOS_SD`, sinon
  stage-1 monte la SD.

## Plan

| # | tâche | sortie vérifiable |
|---|---|---|
| 1 | option `nixelec.bootloader` + câblage (extlinux, montage `/boot`) | `nix eval` : `boot.loader.generic-extlinux-compatible.enable` et `fileSystems."/boot"` suivent l'option, dans les deux sens |
| 2 | branche vendor de `install.sh` + `ubootTools` | sur une unité vendor : `install.sh --vendor` termine, `uEnv.ini`/autoscript portent `init=<toplevel>` == profil `system` |
| 3 | garde de schéma | `install.sh --vendor` sur cible `mainline` et l'inverse sortent en code ≠ 0 **avant** le premier `dd` |
| 4 | `--no-bl33` | sur la N5 déjà migrée, `install.sh --mainline --no-bl33` ne modifie pas le FIP (sha256 du secteur 1 identique) |
| 5 | bout en bout, unité sacrifiable | vendor : boot sans SD après installation ; puis `uboot-install.sh` + `switch` → boot extlinux, `reboot` et la génération courante suit |
| 6 | non-régression N5 | la carte de référence redémarre sur `smag5grw…` après un `switch` sans toucher la FAT, si l'étape 1 est faite |

## Risques

- **Charge utile pour le mauvais toplevel** : `init=` figé sur une génération
  absente du store de p2 → panique `Attempted to kill init`. Parade : comparaison
  avec `/mnt/n5/nix/var/nix/profiles/system` avant de conclure, pas seulement
  entre fichiers.
- **Deux schémas dans un seul script** : surface doublée. Parade : gardes
  croisées (étape 3) et un schéma explicite à l'appel, jamais déduit.
- **Le schéma vendor n'a de sens que si la charge utile est rafraîchie** après
  chaque `switch` (C8 `havenos payload`, C10 hook). Sans le hook, l'installateur
  vendor installe une carte qui redevient « une génération en retard » au premier
  rebuild — c'est accepté, mais doit être écrit dans la doc de l'installateur.
- **`mkimage` sur la cible** : la branche vendor dépend d'un outil de plus dans
  la fermeture ; s'il manque, l'échec est tardif (après formatage). Contrôle
  explicite en étape 3.

## Critères de sortie

1. une unité **vendor** installée par `install.sh --vendor` démarre sans SD, et
   la carte SD de l'installateur reste démarrable (extlinux écrit par
   `n5-boot.nix` sur son propre média) ;
2. la même unité, migrée par `uboot-install.sh` puis un `switch`, démarre en
   extlinux et **`switch` survit au reboot** (montage `/boot` en place) ;
3. les deux mismatches sont refusés, avec un message qui nomme le schéma attendu
   et la valeur trouvée ;
4. aucune régression sur la N5 de référence : `readlink /run/current-system`
   == `nix eval` après un `switch` + reboot, sans intervention sur la FAT.

## Ce qui invaliderait cette spec

- toutes les unités sont migrées mainline avant la prochaine installation et le
  bootstrap disparaît : le schéma vendor n'a plus de cible, la spec tombe ;
- le BL33 mainline se révèle inutilisable sur une unité neuve (FIP refusé,
  MaskROM) : c'est alors **vendor par défaut** et mainline pour les unités
  prouvées — l'inverse du défaut proposé, mais la même structure ;
- le hook vendor rend la charge utile auto-portante au point qu'un installateur
  vendor devient inutile (peu probable : il faut bien une première charge utile
  sur une unité nue).
