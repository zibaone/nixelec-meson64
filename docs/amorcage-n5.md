# Amorçage de la N5 : deux schémas, selon le chargeur

## Ce qui pilote quoi

| chargeur | ce qu'il lit | générations |
|---|---|---|
| U-Boot **vendor** (2015.01) | `boot.scr` → `uEnv.ini` → `init=/nix/store/<génération>` | **une seule**, figée dans un fichier |
| U-Boot **mainline** (2027.01) | `extlinux/extlinux.conf` → `/nixos/<hash>-linux-…/Image` | une entrée par génération, `configurationLimit` |

Le vendor n'a ni `sysboot` ni `extlinux` : c'est structurel, pas un réglage
(`docs/uboot-mainline.md`). Une carte migrée (BL33 mainline) utilise le second
schéma ; une carte restée sur le vendor utilise le premier.

## Schéma épinglé (cartes sur le vendor)

U-Boot lit `boot.scr` sur la partition FAT `NIXOS_BOOT`, qui lit `uEnv.ini`,
qui contient `init=/nix/store/<génération>/init`. C'est **une génération figée
dans un fichier**, pas une liste d'entrées. La charge utile (noyau, initrd, DTB,
`boot.scr`, `uEnv.ini`) est produite par `mkBootFiles` — côté flotte,
`havenos-n5-boot-payload`.

### Conséquence : `nixos-rebuild switch` ne survit pas à un reboot

`switch` change le système en cours d'exécution et le lien
`/nix/var/nix/profiles/system`, mais **pas** `uEnv.ini`. Au reboot suivant,
U-Boot relit son `init=` figé et redémarre l'ancienne génération. Symptôme
observé : après un `switch` réussi, la carte revient avec le hostname de la
veille et `serial-getty@ttyS0` en échec.

Deux façons de vivre avec, tant que la carte est sur le vendor :

1. **Rafraîchir la charge utile avant chaque reboot** :

   ```sh
   P=$(nix build .#havenos-n5-boot-payload --no-link --print-out-paths)
   nix copy --to ssh://root@<ip> "$P"
   # sur la carte
   mount /dev/mmcblk0p1 /mnt/nb
   cp -fL "$P"/* /mnt/nb/ && sync && umount /mnt/nb
   ```

   Vérifier que `uEnv.ini` et `boot.scr` portent bien le même
   `init=/nix/store/<32 car.>`, et que le DTB est identique (`cmp`).

2. **Automatiser** : un service qui, après activation, reconstruit la charge
   utile depuis `system.build.toplevel` et la recopie sur `NIXOS_BOOT`.

## Schéma mainline (carte migrée)

`boot.loader.generic-extlinux-compatible` est activé par le module de carte
(`modules/boards/magicsee-n5.nix`). À chaque activation — y compris pendant
`nixos-install` — NixOS écrit :

- `extlinux/extlinux.conf` à la racine de `NIXOS_BOOT`, une entrée par
  génération, avec `APPEND init=<toplevel>/init …` ;
- sous `/boot/nixos/`, le noyau (`Image`, 38 Mo), l'initrd (24 Mo) et le DTB
  de chaque génération conservée.

`configurationLimit = 3` : `p1` fait 488 Mio et une génération y coûte ~63 Mo.
Sans limite, la septième reconstruction remplit la partition et échoue en
pleine écriture.

`nixos-rebuild switch` suffit donc : la génération suivante est écrite dans
`/boot`, le chargeur la liste au reboot, et une génération précédente reste
sélectionnable dans le menu (timeout 5 s).

La SD de l'installateur porte elle aussi un `extlinux/extlinux.conf` (écrit par
`n5-boot.nix`), en plus des scripts épinglés : sans lui, une SD ne démarrerait
plus sur une boîte déjà migrée, puisque le mainline numérote la SD `mmc 1` là
où le vendor la numérote `mmc 0`.

## Qui écrit quoi, et où ça manque

| geste | ce qu'il écrit | état |
|---|---|---|
| installateur, schéma **vendor** | charge utile initiale (`uImage`, `uInitrd`, autoscripts, `uEnv.ini`, DTB) | **absent du code actuel** — Spec 03 |
| installateur, schéma **mainline** | `extlinux.conf` (écrit par `nixos-install`), puis le BL33 | présent, mesuré sur la N5 |
| `nixos-rebuild switch` (mainline) | `extlinux.conf` + `/nixos/<hash>/…` sur `NIXOS_BOOT` | **bloqué** : `/boot` n'est pas monté sur la FAT |
| `havenos payload` (vendor) | charge utile réécrite avec le nouveau `init=` | existe (C8) ; le hook qui l'enchaîne à l'activation est C10 |

Le troisième point est le maillon qui transforme le schéma mainline en schéma
« où `switch` suffit » : sans le montage, l'activation écrit dans l'ext4 et la
FAT garde l'entrée du dernier `dd`. Montage, `configurationLimit` et option de
schéma sont traités ensemble dans `docs/specs/03-installateur-deux-schemas.md`.

## Pièges

- **Étiquette de racine** : SD et eMMC partagent `NIXOS_SD`
  (`examples/magicsee-n5-bringup.nix`). Avec une SD NixOS insérée, stage-1 peut
  monter la racine de la SD. Le correctif propre est une étiquette distincte
  pour la cible (`NIXOS_EMMC`) ; en attendant, épingler `root=` par `PARTUUID`
  dans l'`extlinux.conf` de la carte.
- `cp` **sans** `-L` échoue ou copie des liens : les fichiers du store sont
  liés en dur, et FAT ne connaît pas les liens durs.
- Sauvegarder `uEnv.ini` et `boot.scr` avant écrasement (`old-<date>/`) permet
  de revenir en arrière sans reflasher.
- La partition d'amorçage **n'est pas montée** par le système (mesuré :
  `findmnt -T /boot` rend `/`), donc `nixos-rebuild` n'écrit pas dans la FAT.
  Ce n'est pas un détail d'ergonomie : c'est ce qui empêche le schéma mainline
  de tenir sa promesse (« `switch` suffit »). Le montage et l'option de schéma
  sont dans `docs/specs/03-installateur-deux-schemas.md`.
- Le noyau et l'initrd sont **dans** la charge utile : une génération différente
  implique aussi un noyau différent (fragment VPU stateful ou non). Copier
  `uEnv.ini` seul ne suffit pas.
