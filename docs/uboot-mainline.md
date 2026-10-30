# Remplacer le U-Boot vendor (Amlogic gxl, S905X / p212)

État au 2026-10-30 : **construction amont qui passe**, rien n'a encore été écrit
sur la carte. Ce document décrit la voie sans risque avant les écritures
irréversibles.

## Pourquoi

Aujourd'hui l'image SD nixelec n'écrit **aucun** binaire d'amorçage
(`firmwarePartitionOffset = 1`, premier MiB vide) : les deux médias dépendent du
U-Boot vendor présent dans les 668 premiers MiB de la eMMC. Une carte à eMMC
effacée ne démarre plus du tout, seule issue le MaskROM Amlogic.

Le U-Boot vendor fonctionne pour autant : il lit correctement `Image` (38 Mo),
`initrd` (25 Mo), `boot.scr` et le DTB depuis la eMMC. Les incidents du 30/10
avaient trois autres causes (nom `emmc_autoscript`, écriture non arrivée sur le
média, format d'initrd refusé par `bootm`). Le motif du remplacement est donc la
**dépendance**, pas la fiabilité.

## Ce qui est prêt

- `nix develop .#uboot` : chaîne croisée `aarch64-unknown-linux-gnu-`,
  `ubootTools`, `dtc`, `swig`/`bc`/`bison`/`flex`, `pyusb` + `libusb1`,
  `picocom`/`minicom`. `ARCH=arm64` et `CROSS_COMPILE` posés par le shellHook.
- `scripts/uboot-p212.sh` : clone/actualise U-Boot amont, `p212_defconfig`,
  construit, et copie les artefacts dans `build-uboot/out/`.

Résultat mesuré le 30/10 (U-Boot amont, `p212_defconfig`) :

| artefact | taille |
|---|---|
| `u-boot.bin` | 794 448 o |
| `u-boot.dtb` | 44 704 o |
| `u-boot.bin.sd.bin` | **non produit** par cette cible |

Le `.sd.bin` est le format attendu par la ROM : un en-tête Amlogic de 512 octets
(`AML`) suivi du binaire, avec la taille et la somme de contrôle. Mainline ne
l'émet pas — il faut soit l'outillage vendor (`aml_encrypt_gxl`), soit passer par
le MaskROM.

## Étape 1 — validation sans écriture (à faire d'abord)

La ROM Amlogic accepte un binaire **par USB OTG** (câble A-A, celui de
l'opérateur). Le binaire est chargé en RAM et exécuté : rien n'est écrit, donc
rien ne peut être brické.

```sh
nix develop .#uboot
python3 -m venv .venv-amlboot
.venv-amlboot/bin/pip install pyamlboot

# carte en MaskROM : alimentation coupée, maintenir le bouton reset (ou shunter
# l'eMMC), brancher l'USB A-A, puis alimenter
.venv-amlboot/bin/amlboot boot build-uboot/out/u-boot.bin
```

Si la console série affiche le prompt mainline, la cible est bonne et la suite
devient une simple question d'écriture.

## Étape 2 — SD avant eMMC

Une fois le binaire validé en RAM, l'écrire en tête de SD. La ROM préfère la SD
si son en-tête est valide et retombe sur la eMMC sinon : **une SD ratée ne
brique rien**, il suffit de la retirer.

L'écriture en eMMC (`boot0`, en-tête Amlogic) ne vient qu'après, avec la
procédure MaskROM ci-dessus écrite noir sur blanc et testée.

## Pièges déjà rencontrés, à ne pas réintroduire

- `booti` exige un noyau **aligné sur 2 Mio** : `0x1080000` ne l'est pas, d'où
  l'exception et la boucle de reset. Utiliser `0x2000000`.
- `bootm` refuse un initrd brut (« Wrong Ramdisk Image Format ») ; `booti`
  l'accepte avec `adresse:taille`.
- Le U-Boot vendor cherche `emmc_autoscript` sur `mmc 1` et `s905_autoscript` sur
  `mmc 0` : les deux noms doivent être présents.
- `stat -c %s` sur un lien du store mesure le lien (96 o) : utiliser `stat -L`.
