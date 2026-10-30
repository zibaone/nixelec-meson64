#!/usr/bin/env bash
# Construit U-Boot mainline pour l'Amlogic gxl (S905X, carte p212) et sort les
# artefacts d'amorçage. À lancer depuis `nix develop .#uboot`.
#
#   ./scripts/uboot-p212.sh            # clone (ou met à jour) puis construit
#   UBOOT_SRC=/chemin ./scripts/uboot-p212.sh   # arbre existant
#
# Produit :
#   $out/u-boot.bin           — image nue
#   $out/u-boot.bin.sd.bin    — image SD (en-tête Amlogic pour la ROM)
#
# Rappel de sûreté : écrire sur la SD ne risque rien (la ROM retombe sur la
# eMMC si l'en-tête SD est invalide). Écrire dans la eMMC, si.
set -euo pipefail

: "${CROSS_COMPILE:=aarch64-unknown-linux-gnu-}"
: "${ARCH:=arm64}"
export CROSS_COMPILE ARCH

work="${UBOOT_WORK:-$PWD/build-uboot}"
src="${UBOOT_SRC:-$work/u-boot}"
defconfig="${UBOOT_DEFCONFIG:-p212_defconfig}"
out="${UBOOT_OUT:-$work/out}"

mkdir -p "$work" "$out"

if [ -n "${UBOOT_SRC:-}" ]; then
  echo "arbre existant : $src"
elif [ -d "$src/.git" ]; then
  echo "mise à jour de $src"
  git -C "$src" fetch --depth=1 origin master
  git -C "$src" reset --hard FETCH_HEAD
else
  echo "clone de U-Boot dans $src"
  git clone --depth=1 https://source.denx.de/u-boot/u-boot.git "$src"
fi

command -v "${CROSS_COMPILE}gcc" >/dev/null || {
  echo "chaîne croisée absente : ${CROSS_COMPILE}gcc introuvable" >&2
  echo "lance ce script depuis « nix develop .#uboot »" >&2
  exit 1
}

echo "configuration : $defconfig"
make -C "$src" O="$work/obj" "$defconfig"

echo "construction ($(nproc) tâches)"
make -C "$src" O="$work/obj" -j"$(nproc)"

inc="$work/obj"
for f in u-boot.bin u-boot.bin.sd.bin u-boot.dtb; do
  if [ -f "$inc/$f" ]; then
    cp -f "$inc/$f" "$out/$f"
    printf '  %-20s %s\n' "$f" "$(stat -c %s "$out/$f") octets"
  else
    echo "  $f absent (le format SD n'est peut-être pas produit par cette cible)" >&2
  fi
done

echo
echo "artefacts dans $out"
echo "SD : la ROM du S905X lit l'en-tête en tête de carte ; on écrit le .sd.bin"
echo "     sudo dd if=$out/u-boot.bin.sd.bin of=/dev/sdX bs=512 conv=fsync status=progress"
echo "     (l'image SD nixelec garde son premier MiB vide : ce binaire l'occupe)"
