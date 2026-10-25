# Cartes de bring-up

| Carte | SoC | Famille | Statut | Rôle |
|---|---|---|---|---|
| Magicsee N5 (modèle d'origine) | S905X | GXL / `meson64` | **confirmé** | référence stateless H.264 |
| Magicsee N5 Plus | S905X3 | SM1 / `meson64` | à confirmer | variante possible |
| Magicsee N5 Max | S905X2 ou S905X3 | G12A/SM1 | à confirmer | variante possible |
| Magicsee N5 Max X4 | S905X4 | SC2 | hors stateless | veille SC2 |
| Vontar X4 | S905X4 | SC2 | hors stateless | veille SC2 |

Le nom « Magicsee N5 » couvre plusieurs générations. **Confirmer le SoC avant
de coder un module board** : la sérigraphie du SoC, ou
`cat /proc/device-tree/compatible` / `getprop ro.board.platform` sous Android.

Le Vontar X4 est un **S905X4/SC2** : il ne peut pas valider le driver
`meson-amvdec` (GX/G12/SM1). Il relève d'un projet SC2 séparé.
