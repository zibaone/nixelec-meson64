#!/usr/bin/env bash
# Construit le FIP Amlogic (BL2 + BL30 + BL31 + notre BL33) pour un S905X.
#
#   ./scripts/uboot-p212.sh          # BL33 : u-boot.bin (mainline, p212_defconfig)
#   ./scripts/uboot-p212-fip.sh      # FIP  : u-boot.bin.sd.bin + variantes USB
#
# `amlogic-boot-fip` (LibreELEC) assemble les blobs SoC avec notre U-Boot :
# c'est lui qui produit les formats que la BootROM sait lire. Sans lui, notre
# build mainline ne donne que le BL33 (`u-boot.bin`), inutilisable seul.
set -euo pipefail

work="${UBOOT_WORK:-$PWD/build-uboot}"
out="${UBOOT_OUT:-$work/out}"
fip_src="$work/amlogic-boot-fip"
fip_out="$work/fip"
# `lepotato` = Libretech Le Potato, S905X (même famille gxl que le p212) : le
# FIP dépend du SoC, pas du modèle de carte.
board="${FIP_BOARD:-lepotato}"

if [ ! -f "$out/u-boot.bin" ]; then
  echo "u-boot.bin absent dans $out — lance d'abord ./scripts/uboot-p212.sh" >&2
  exit 1
fi

for tool in python3 make sh readlink mktemp cat dd; do
  command -v "$tool" >/dev/null || {
    echo "outil manquant : $tool (lance ce script depuis « nix develop .#uboot »)" >&2
    exit 1
  }
done

if [ -d "$fip_src/.git" ]; then
  echo "mise à jour de $fip_src"
  git -C "$fip_src" fetch --depth=1 origin master
  git -C "$fip_src" reset --hard FETCH_HEAD
else
  echo "clone de amlogic-boot-fip dans $fip_src"
  git clone --depth=1 https://github.com/LibreELEC/amlogic-boot-fip.git "$fip_src"
fi

# Les scripts du FIP déclarent `#!/bin/bash`, absent de cet hôte (NixOS ne
# fournit que /bin/sh) : execve rend alors ENOENT et l'on croit à un fichier
# manquant. On bascule sur `env bash`, présent dans le shell de dev.
for f in "$fip_src"/*/blx_fix.sh; do
  [ -f "$f" ] && sed -i '1s|^#!/bin/bash$|#!/usr/bin/env bash|' "$f"
done

mkdir -p "$fip_out"
echo "FIP pour $board à partir de $out/u-boot.bin"
(
  cd "$fip_src"
  ./build-fip.sh "$board" "$out/u-boot.bin" "$fip_out"
)

echo
echo "artefacts FIP dans $fip_out :"
ls -l "$fip_out" | sed 's/^/  /'
cat <<EOF

Écriture, dans l'ordre de sûreté croissant :

1. RAM seulement (rien d'écrit, rien de brickable) :
     amlboot p212 --image $fip_out/u-boot.bin.usb.tpl
   (câble USB A-A ; la ROM doit apparaître comme 1b8e:c003 dans « lsusb »)

2. SD (la ROM préfère la eMMC, donc une SD ratée se retire) :
     sudo dd if=$fip_out/u-boot.bin.sd.bin of=/dev/sdX conv=fsync,notrunc bs=1 count=440
     sudo dd if=$fip_out/u-boot.bin.sd.bin of=/dev/sdX conv=fsync,notrunc bs=512 skip=1 seek=1
   Les 440 premiers octets laissent la table de partitions intacte, comme le
   fait LibreELEC (projects/Amlogic/bootloader/mkimage).

3. eMMC : seulement avec la procédure MaskROM testée et le préfixe de 668 Mio
   sauvegardé (/var/lib/n5-backup/prefix-668MiB.img).
EOF
