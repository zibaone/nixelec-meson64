# Amorçage de la N5 : une charge utile épinglée, et ce que ça implique

## Le mécanisme

La N5 n'utilise pas le schéma NixOS habituel (extlinux ou systemd-boot qui
écrivent une entrée par génération). U-Boot lit `boot.scr` sur la partition FAT
`NIXOS_BOOT`, qui lit `uEnv.ini`, qui contient :

```
init=/nix/store/<génération>/init
```

C'est donc **une génération figée dans un fichier**, pas une liste d'entrées. La
charge utile (noyau, initrd, DTB, `boot.scr`, `uEnv.ini`) est produite par
`mkBootFiles` — côté flotte, `havenos-n5-boot-payload`.

## Conséquence : `nixos-rebuild switch` ne survit pas à un reboot

`switch` change le système en cours d'exécution et le lien
`/nix/var/nix/profiles/system`, mais **pas** `uEnv.ini`. Au reboot suivant,
U-Boot relit son `init=` figé et redémarre l'ancienne génération. Symptôme
observé le 30 octobre : après un `switch` réussi, la carte est revenue en
`hostname=havenos` avec `serial-getty@ttyS0` en échec — la génération de la
veille.

Ce n'est pas une régression : c'est le prix du schéma. Deux façons de vivre avec :

1. **Rafraîchir la charge utile avant chaque reboot** (ce qui est fait ici) :

   ```sh
   # sur le poste
   P=$(nix build .#havenos-n5-boot-payload --no-link --print-out-paths)
   nix copy --to ssh://root@<ip> "$P"
   # sur la carte
   mount /dev/mmcblk0p1 /mnt/nb
   cp -fL "$P"/* /mnt/nb/ && sync && umount /mnt/nb
   ```

   Vérifier ensuite que `uEnv.ini` et `boot.scr` portent bien le même
   `init=/nix/store/<32 car.>`, et que le DTB est identique (`cmp`).

2. **Automatiser** : un service qui, après activation, reconstruit la charge
   utile depuis `system.build.toplevel` et la recopie sur `NIXOS_BOOT`. À faire
   si les redémarrages deviennent fréquents.

## Pièges

- `cp` **sans** `-L` échoue ou copie des liens : les fichiers du store sont
  liés en dur, et FAT ne connaît pas les liens durs.
- Sauvegarder `uEnv.ini` et `boot.scr` avant écrasement (`old-<date>/`) permet
  de revenir en arrière sans reflasher.
- La partition d'amorçage n'est pas montée par le système : `findmnt /boot`
  échoue, il faut monter `/dev/mmcblk0p1` soi-même.
- Le noyau et l'initrd sont **dans** la charge utile : une génération
  différente implique aussi un noyau différent (fragment VPU stateful ou non).
  Copier `uEnv.ini` seul ne suffit pas.
