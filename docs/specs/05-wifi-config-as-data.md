# Spec 05 — WiFi config-as-data

## Problème mesuré

`nixelec.wifi` ne savait rendre qu'un couple `ssid` + `pskFile` : le SSID et la
liste des réseaux vivaient dans la configuration Nix (donc dans le store), et
le PSK dans un fichier séparé. Conséquences :

- changer de réseau (déménagement, hotspot, autre site) = rebuild + deploy ;
- une carte ne peut pas suivre plusieurs réseaux sans code ;
- l'identité WiFi d'une carte n'est pas une donnée, alors que le provisioning
  M2 sait déjà pousser des fichiers au boot.

## Décision

Ajouter `nixelec.wifi.networksFile` (`nullOr str`, défaut `null`) : chemin
d'un **fichier wpa_supplicant complet** (un ou plusieurs blocs `network={…}`),
lu au boot et **prioritaire** sur `ssid`/`pskFile` quand il existe.

- le fichier est copié tel quel dans `/run/wpa_supplicant.conf` (`umask 077`) :
  aucune analyse, aucun SSID interpolé, rien de cuit dans le store ;
- `ssid`/`pskFile` restent le **repli** : images de secours, hôtes non migrés,
  migration sans coupure ;
- `wpa-psk` et `wpa-supplicant` sont créés dès qu'une des deux sources est
  déclarée ; `wpa-supplicant` porte `ConditionPathExists=/run/wpa_supplicant.conf`
  et des limites de redémarrage (une conf absente ne boucle plus — 49
  redémarrages mesurés sur la Zero 3).

## Contrat côté HavenOS

`services.havenos.wifiNetworks` pointe la couche sur
`/run/havenos/wifi-networks` (rendu par `havenos-secrets` depuis
`secrets/wifi-networks.age`) et publie `wifi-networks` au contrat de l'image.
Le profil `kodi-standalone` cesse de déclarer `ssid`/`pskFile` sur un hôte
migré, et le contrat nomme `wifi-networks` au lieu de `wifi-psk`.

Ajouter ou retirer un réseau = rééditer le secret puis `havenos provision` :
aucun rebuild.

## Vérifié (N5, 2026-11-08)

Deux blocs (`Livebox-4FE0`, `S23 Ultra`) ; après deploy + provision, la conf
rendue contient les deux réseaux, `wlan0` s'associe au hotspot et prend un bail
DHCP (192.168.43.205). Rejeu `wpa-psk` → `wpa-supplicant` : idem. Reboot :
la conf est re-rendue depuis le secret au démarrage.

## Limites

- Pas de réécriture à chaud : le fichier est rendu au boot (ou au restart de
  `wpa-psk`) ; une API d'écriture (`runtimeConfigFile` inscriptible, privilèges
  `wpa_cli`) reste ouverte côté HavenOS (spec `havenos-settings.md` D2/D3).
- `nixelec-sunxi64` (UWE5622, `wifiClient`) n'expose pas encore l'option : la
  Zero 3 garde `ssid`/`pskFile` tant que le même patron n'y est pas porté.
