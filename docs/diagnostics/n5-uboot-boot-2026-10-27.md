# N5 — boot NixOS par le vendor U-Boot

> Relevé UART du 2026-10-27, `ttyAML0` 115200 8N1. **Le boot NixOS complet est
> validé** : initrd chargé, `root=LABEL=NIXOS_SD` monté, systemd PID 1 sur la
> racine réelle, `Multi-User System` atteint et shell root sur `ttyAML0`.
> Capture brute : `/tmp/opencode/n5-boot-multi-2205.log` (épisode sans `init=`)
> et `/tmp/opencode/n5-boot.raw` (boot validé).

## Chaîne validée

U-Boot vendor 2015.01 (`gxl_p212_v1`, BL33 en eMMC) → `s905_autoscript` (FAT
`mmc 0:1`) → `uImage.multi` (noyau + initrd) + DTB p212 → `bootm` → Linux
7.0.14 → initrd systemd → `LABEL=NIXOS_SD` → switch-root → NixOS 26.05.

```
reading s905_autoscript
634 bytes read in 4 ms (154.3 KiB/s)
## Executing script at 01020000
reading uImage.multi
63519184 bytes read in 5441 ms (11.1 MiB/s)
reading meson-gxl-s905x-p212.dtb
40957 bytes read in 9 ms (4.3 MiB/s)
Booting NixOS from mmc 0:1
## Booting kernel from Legacy Image at 20000000 ...
   Image Name:   NixOS multi
   Image Type:   AArch64 Linux Multi-File Image (uncompressed)
   Contents:
      Image 0: 38361600 Bytes = 36.6 MiB
      Image 1: 25157508 Bytes = 24 MiB
   Verifying Checksum ... OK
## Loading init Ramdisk from multi component Legacy Image at 20000000 ...
   Loading Ramdisk to 726a3000, end 73ea0f84 ... OK
   Loading Device Tree to 000000001fff3000, end 000000001ffffffc ... OK
Starting kernel ...
```

Côté noyau :

```
Linux version 7.0.14 (nixbld@localhost) (aarch64-unknown-linux-gnu-gcc 15.3.0) #1-NixOS SMP PREEMPT
Machine model: Amlogic Meson GXL (S905X) P212 Development Board
soc soc0: Amlogic Meson GXL (S905L) Revision 21:d (c4:2) Detected
Kernel command line: console=ttyAML0,115200n8 cma=256M root=LABEL=NIXOS_SD rootwait rw init=/nix/store/4asalr9ha…-nixos-system-magicsee-n5-sd-card-26.05.20261020.cd4ea8d/init
mmcblk0: mmc0:fca9 SU02G 1.89 GiB   → mmcblk0: p1 p2
mmcblk1: mmc1:0001 MAG2GC 14.6 GiB → mmcblk1: p1 p2, boot0/boot1 4 MiB, rpmb
```

Puis la bascule vers la racine :

```
systemd[1]: Running in initrd.
Booting initrd of NixOS 26.05 (Yarara) (Initrd).
[  OK  ] Found device /dev/disk/by-label/NIXOS_SD.
[  OK  ] Mounted /sysroot.
[  OK  ] Started Find NixOS closure.
[  OK  ] Set Switch Root.
Welcome to NixOS 26.05 (Yarara)!
[  OK  ] Reached target Multi-User System.
[root@magicsee-n5:~]#
```

## Cause racine du premier échec : `init=` absent

Le multi-image était correct, le disque montait, mais le boot s'arrêtait sur :

```
[FAILED] Failed to start Find NixOS closure.
[DEPEND] Dependency failed for Initrd Default Target.
[  OK  ] Started Emergency Shell.
Cannot open access to console, the root account is locked.
```

Le script `initrd-find-nixos-closure-start` ne cherche pas le closure en
scannant `/sysroot/nix/store` : il **lit `init=` dans `/proc/cmdline`**.

```sh
for o in $(< /proc/cmdline); do
    case $o in
        init=*) closure="${initParam[1]}" ;;
    esac
done
if [ -z "${closure:-}" ]; then
  echo 'No init= parameter on the kernel command line' >&2
  exit 1
fi
```

GRUB, extlinux et systemd-boot injectent cet argument ; notre autoscript vendor
écrit `bootargs` à la main et ne le faisait pas. Le closure était pourtant bien
présent dans la partition racine (460 entrées dans `/nix/store`, dont
`4asalr9ha…-nixos-system-magicsee-n5-sd-card-…`).

Correctif : `n5-boot.nix` construit désormais la ligne de commande avec
`init=${toplevel}/init`, où `toplevel` vaut `config.system.build.toplevel`
(image SD) ou `n5TargetSystem` (installateur). L'argument est ajouté dans le
script de boot et **non** dans `boot.kernelParams`, pour ne pas changer le
toplevel donc la clé de cache : seule la partition FAT est reconstruite.

## Échecs mesurés plus tôt (historique)

### `booti` sans `fdtaddr`

```text
[rsvmem] get fdtaddr NULL!
rsvmem check failed
"Synchronous Abort" handler, esr 0x96000210
```

### DTB p212 mainline sans `reserved-memory`

```text
libfdt fdt_path_offset() returned FDT_ERR_NOTFOUND
[rsvmem] fdt get prop fail.
"Synchronous Abort" handler, esr 0x96000210
```

Le DTB mainline n'a pas le nœud `reserved-memory` attendu par `rsvmem`/`booti`
du vendor : `booti` est donc inutilisable tel quel.

### `bootm` sans initrd

```text
Kernel command line: console=ttyAML0,115200n8 cma=256M root=LABEL=NIXOS_SD rootwait rw
VFS: Cannot open root device "LABEL=NIXOS_SD" or unknown-block(0,0): error -6
Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(0,0)
```

Le noyau voyait `mmcblk0p2` mais le noyau seul ne résout pas un label : d'où
l'initrd obligatoire.

## Anomalies secondaires relevées

Non bloquantes, mais à traiter :

- **`init=` obligatoire** (corrigé, voir plus haut).
- **`zram` absent des modules** : nixbian active `zramSwap` (atténuation
  d'usure SD, `nix/parts/nixos-module.nix:489`) alors que
  `parts/modules.nix` force un `system.modulesTree` élagué
  (`pruneKernelModules`) qui ne garde pas `drivers/block`. Résultat :
  `modprobe: FATAL: Module zram not found`, `dev-zram0.swap` en attente puis
  expiration toutes les 90 s, et bruit permanent sur la console. Le noyau a
  bien `CONFIG_ZRAM=m` (`/proc/config.gz`). Correctif : `zram` ajouté à
  `hardware.nixbian.kernelModules.extraKeep` — **vérifié le 2026-10-28** :
  `zram: Added device: zram0`, swap `zstd` de 896 Mio actif,
  `systemctl list-jobs` vide.
- **Carte SD** : `meson-gx-mmc d0072000.mmc: error -EINVAL:
  request_irq(28) 0x0 mmc_gpio_cd_irqt` — l'IRQ de détection de carte échoue,
  mais `mmc0` et `mmcblk0` sont bien créés et le boot aboutit.
- **`initrd-fstab`** : `systemd-fstab-generator: Failed to create unit file
  '/run/systemd/generator/sysroot.mount', as it already exists. Duplicate
  entry` — avertissement, `/sysroot` est monté correctement.
- **U-Boot** : `[rsvmem] fdt get prop fail` reste affiché pendant `bootm` mais
  n'est plus fatal ; le noyau signale `[Firmware Bug]: Kernel image misaligned
  at boot, please fix your bootloader!` (le vendor charge à `0x01080000`).

## Reste à mesurer

- Décodage H.264 1080p avec `h264_v4l2request` : impossible dans cette image,
  qui ne contient ni `v4l2-ctl`, ni `ffmpeg`, ni Nix (seuls présents : bash,
  coreutils, iproute2, kmod, less, nano, procps, util-linux).
- Zram après correctif `extraKeep`.
- Boot depuis la eMMC via l'installateur (préfixe 668 Mio + `boot0`/`boot1` à
  sauvegarder d'abord).
