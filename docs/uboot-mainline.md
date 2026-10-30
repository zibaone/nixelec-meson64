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

## Résultat du 30/10 : MaskROM refuse le payload

Quatre tentatives de charger le FIP en RAM par USB OTG (`amlboot p212`), sur deux
ports et avec deux BL2 différents :

| tentative | résultat |
|---|---|
| BL2 de pyamlboot (`files/p212`), port 1 | `Errno 5` à la première écriture mémoire |
| BL2 de notre FIP, port 1 | `Errno 5` au même endroit |
| idem, port USB 2 (`Bus 003`) | `Errno 19` : le périphérique **se déconnecte** |
| BL2 écrit par `REQ_WR_LARGE_MEM` (0x11), outil lancé **avant** la carte | `Errno 110` : timeout bulk |

`dmesg` est sans ambiguïté : `New USB device found, idVendor=1b8e, idProduct=c003`
puis `USB disconnect` — aucune erreur de bus, aucun `error -71`. Le lien est sain ;
c'est le ROM qui coupe, systématiquement, à la première écriture mémoire. Le
lancement avant la carte (fenêtre de ~20 s du chien de garde) ne change rien.

**Hypothèse retenue : secure boot activé.** Le BL1 n'accepte qu'un BL2 signé par
Amlogic : il laisse l'identification (`ROM: 0.7 Stage: 0.16`) puis rejette tout
chargement.

### Conséquence : la voie SD devient risquée

Si le ROM vérifie les signatures, il refusera aussi notre FIP sur la SD. Or
neutraliser le chargeur eMMC (écrire des zéros dans le premier Mio) pour forcer
la SD serait alors **sans retour** : plus de chargeur eMMC, FIP SD refusé, et un
MaskROM qui n'écrit rien. **Ne pas tenter sans preuve préalable que le ROM accepte
un FIP non signé.**

### Ce qui reste praticable

1. Garder le U-Boot vendor (il lit correctement nos fichiers : mesuré, `Image`,
   `initrd`, `boot.scr` et le DTB passent le CRC depuis la eMMC).
2. Refaire une installation propre **avec l'alimentation neuve** : les derniers
   échecs de démarrage venaient de fichiers faux sur le média (`Bad Data CRC` y
   compris sur `uImage`), écrits avant le changement d'alimentation.
3. Utiliser la recette de référence (`uImage` + `uInitrd` + DTB, `bootm` à trois
   arguments) qui est celle des cartes Amlogic à U-Boot vendor.
