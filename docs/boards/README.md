# Cartes de bring-up

| Carte | SoC | Famille | Statut | Rôle |
|---|---|---|---|---|
| Magicsee N5 (modèle d'origine) | **S905L** | GXL / `meson64` | **mesuré 2026-10-26** | référence stateless H.264 |
| Magicsee N5 Plus | S905X3 | SM1 / `meson64` | à confirmer | variante possible |
| Magicsee N5 Max | S905X2 ou S905X3 | G12A/SM1 | à confirmer | variante possible |
| Magicsee N5 Max X4 | S905X4 | SC2 | hors stateless | veille SC2 |
| Vontar X4 | S905X4 | SC2 | hors stateless | veille SC2 |

Le nom « Magicsee N5 » couvre plusieurs générations. Le modèle d'origine de
ce dépôt a été mesuré **S905L/GXL** (pas S905X) le 2026-10-26 : voir
[`magicsee-n5.md`](magicsee-n5.md). Pour toute autre boîte, confirmer le SoC
avant de coder un module board.

Le Vontar X4 est un **S905X4/SC2** : il ne peut pas valider le driver
`meson-amvdec` (GX/G12/SM1). Il relève d'un projet SC2 séparé.
