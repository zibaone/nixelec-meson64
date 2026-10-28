# N5 — diagnostic du boot par le vendor U-Boot

> Relevé UART du 2026-10-27. **Le noyau 7.0.14 est atteint via `bootm` ; le
> système NixOS complet n'est pas encore validé.**

## Chaîne

U-Boot vendor 2015.01 (`gxl_p212_v1`) → `s905_autoscript` sur la SD →
chargement de `Image` + DTB p212 + initrd → `booti` ou `bootm`.

Le prompt U-Boot peut être arrêté avec `Ctrl+C` pendant l'autoboot. Variables
utiles relevées : `bootcmd=run start_autoscript; run storeboot`,
`storeboot=... bootm ${loadaddr}`, `preboot=run bcb_cmd; ...`.

## Échecs mesurés

### `booti` sans `fdtaddr`

Le premier script utilisait `booti` avec `fdt_addr`, mais pas la variable
`fdtaddr` attendue par le vendor :

```text
[rsvmem] get fdtaddr NULL!
rsvmem check failed
"Synchronous Abort" handler, esr 0x96000210
```

Ajout de `fdtaddr=0x1000000` : le chemin suivant apparaît.

### DTB p212 mainline sans `reserved-memory`

```text
libfdt fdt_path_offset() returned FDT_ERR_NOTFOUND
[rsvmem] fdt get prop fail.
"Synchronous Abort" handler, esr 0x96000210
```

Le DTB mainline p212 ne contient pas le nœud `reserved-memory` attendu par
`rsvmem`/`booti` du vendor. `booti` n'est donc pas utilisable tel quel.

### `bootm` sans initrd

Test manuel au prompt U-Boot avec `uImage` + `fdtaddr` :

```text
Kernel command line: console=ttyAML0,115200n8 cma=256M root=LABEL=NIXOS_SD rootwait rw
...
VFS: Cannot open root device "LABEL=NIXOS_SD" or unknown-block(0,0): error -6
Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(0,0)
```

Le noyau démarre et voit `mmcblk0p2`, mais sans initrd il ne peut pas résoudre
le label `NIXOS_SD`. L'initrd n'était pas transmis par ce `bootm`.

## Correctif en cours

Le script construit maintenant une **uImage multi** avec le noyau et l'initrd :

```text
Image Name:   NixOS multi
Image Type:   AArch64 Linux Multi-File Image (uncompressed)
Data Size:    63519120 Bytes
Contents:
  Image 0: 38361600 Bytes
  Image 1: 25157508 Bytes
```

Le script charge `uImage.multi`, charge le DTB p212 séparément à `fdtaddr`,
puis appelle `bootm`. Il positionne `loadaddr`, `fdtaddr`, `initrdaddr`,
`kernel_addr`, `fdt_addr` et `initrd_addr`. `booti` n'est plus utilisé.

L'image test a été réécrite sur la SD 2 Go ; le boot complet reste à confirmer
au prochain démarrage.

## Options si le multi-image échoue

1. Ajouter un nœud `reserved-memory` au DTB p212 (ou utiliser un DTB vendor
   qui le contient) pour réessayer `booti`.
2. Chaîner un U-Boot mainline en `u-boot.ext` et utiliser `extlinux.conf`.
3. Ne jamais écrire une image complète à l'offset 0 de la eMMC : le
   bootloader vendor occupe les 668 premiers MiB.
