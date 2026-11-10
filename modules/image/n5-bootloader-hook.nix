{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.nixelec;
  hook = cfg.bootloaderHook;

  # Constantes d'évaluation, figées dans le script. Elles ne dépendent pas du
  # toplevel, donc les citer ne crée pas le cycle décrit plus bas.
  dtbName = config.hardware.deviceTree.name;
  dtbBase = builtins.baseNameOf dtbName;
  rootLabel = cfg.rootLabel;
in
{
  options.nixelec.bootloaderHook.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Reconstruit la charge utile au switch quand le chargeur ne lit pas
      extlinux.

      En schéma `vendor`, le U-Boot d'origine lit `s905_autoscript` /
      `emmc_autoscript` sur `NIXOS_BOOT`, où `init=` est figé. Un
      `nixos-rebuild switch` met à jour le profil et le store, mais pas cette
      charge utile : au reboot le chargeur relance l'ancienne génération
      (mesuré le 1/11). Le service `nixelec-bootloader-hook.service` la
      régénère depuis le toplevel réellement activé (`/run/current-system`),
      la recopie sur `NIXOS_BOOT`, puis relit la partition en lecture seule et
      compare les sha256.

      Le service est un oneshot lancé après l'activation (via la liste de
      redémarrage de `switch-to-configuration`, donc à chaque `switch`) et
      après `multi-user.target` au démarrage : il ne bloque pas le boot. Il est
      idempotent — si `init=` et les tailles sont déjà ceux du toplevel, il
      n'écrit rien — et il sort 0 avec un message si `NIXOS_BOOT` est absente
      (cible non-N5). Toute autre erreur laisse l'unité en échec : le boot est
      marqué « degraded » mais n'est pas empêché.

      Défaut `false` : à n'activer que sur une unité restée vendor. Sans effet
      en schéma `mainline`, où `extlinux` suit déjà les générations.
    '';
  };

  config = lib.mkMerge [
    {
      warnings = lib.optional (hook.enable && cfg.bootloader == "mainline") ''
        nixelec.bootloaderHook.enable est posé sur une unité déclarée
        `mainline` : la charge utile vendor n'y sert à rien, `extlinux` suit
        déjà les générations. Laisser l'option à false, ou repasser l'unité en
        `vendor` avant de l'activer.
      '';

      # Planification : un oneshot `wantedBy = multi-user.target` est démarré
      # par `switch-to-configuration` quand il est nouveau, mais PAS à chaque
      # `switch` suivant — le texte de l'unité ne change pas, puisque le
      # toplevel est résolu à l'exécution. Le mécanisme prévu pour ça est la
      # liste de redémarrage que l'activation remplit :
      # `/run/nixos/activation-restart-list` (même idiome que
      # `nixos/tests/restart-by-activation-script.nix`). L'unité est donc
      # redémarrée après chaque activation, une fois `/run/current-system`
      # basculé sur la nouvelle génération.
      #
      # Un `system.activationScripts` qui ferait le travail lui-même serait
      # plus court, mais : il bloque l'activation (127 Mo + sha256 sur SD), et
      # un échec — FAT pleine, carte absente — ferait échouer tout le switch,
      # donc l'activation du système. Le service, lui, est rejouable
      # (`systemctl start nixelec-bootloader-hook`), visible au journal, et
      # retenté à chaque boot.
      system.activationScripts.nixelec-bootloader-hook = {
        supportsDryActivation = true;
        text = ''
          if [ "''${NIXOS_ACTION:-}" = "dry-activate" ]; then
            echo nixelec-bootloader-hook.service >> /run/nixos/dry-activation-restart-list
          else
            mkdir -p /run/nixos
            echo nixelec-bootloader-hook.service >> /run/nixos/activation-restart-list
          fi
        '';
      };
    }

    (lib.mkIf hook.enable {
      systemd.services.nixelec-bootloader-hook = {
        description = "Recopier la charge utile d'amorçage vendor sur NIXOS_BOOT";

        # `WantedBy` = `Wants` : l'échec de l'unité n'empêche pas
        # `multi-user.target` d'être atteint, et l'ordonnancement implicite
        # `After=multi-user.target` la place en fin de boot, hors du chemin
        # critique.
        wantedBy = [ "multi-user.target" ];
        after = [ "local-fs.target" ];

        # Le diesel du service : montage FAT, sha256, mkimage.
        path = [
          pkgs.coreutils
          pkgs.util-linux
          pkgs.gnugrep
          pkgs.gnused
        ];

        serviceConfig = {
          Type = "oneshot";
          # Une fois la génération traitée, l'unité reste « active » : le
          # prochain `switch` la redémarre via la restart-list ci-dessus.
          RemainAfterExit = true;
          # 127 Mo de lecture + écriture + relecture sur une SD lente : le
          # délai par défaut (90 s) tuerait le service au milieu d'une
          # écriture. Mieux vaut attendre que laisser une FAT à moitié écrite.
          TimeoutStartSec = "10min";
        };

        # Pourquoi la charge utile n'est pas construite par `mkBootFiles` :
        # `mkBootFiles` fige `init=${toplevel}/init` dans l'autoscript, donc sa
        # dérivation dépend de `config.system.build.toplevel` — qui contient ce
        # script, qui contiendrait la dérivation : récursion infinie. On
        # reproduit donc la même recette à l'exécution, avec les mêmes outils
        # (`mkimage`) et le même invariant que `platform_write_boot` (branche
        # vendor de l'installateur) et que `havenos payload` : fermeture
        # présente avant écriture, `init=` = `<toplevel>/init`, gros fichiers
        # avant les scripts, relecture puis sha256.
        script = ''
          set -eu

          toplevel="$(readlink -f /run/current-system)"
          case "$toplevel" in
            /nix/store/*) ;;
            *)
              echo "nixelec-bootloader-hook : /run/current-system -> '$toplevel' hors du store ; rien n'est écrit" >&2
              exit 0
              ;;
          esac
          expected_init="$toplevel/init"

          # ── La fermeture d'abord ────────────────────────────────────────
          # `switch` a construit ce toplevel localement, et un déploiement
          # distant copie la fermeture avant d'activer. On vérifie donc pièce
          # par pièce qu'il est complet AVANT de toucher la FAT : un `init=`
          # qui désigne un chemin absent du store ne démarre pas. Pas d'appel
          # à `nix` — la cible a `nix.enable = false` et n'en a pas besoin.
          for f in init kernel initrd kernel-params "dtbs/${dtbName}"; do
            if [ ! -e "$toplevel/$f" ]; then
              echo "nixelec-bootloader-hook : fermeture incomplète, $toplevel/$f manque ; rien n'est écrit" >&2
              exit 1
            fi
          done

          # ── La cible : une partition, jamais le disque ──────────────────
          dev=/dev/disk/by-label/NIXOS_BOOT
          if [ ! -e "$dev" ]; then
            echo "nixelec-bootloader-hook : aucune partition NIXOS_BOOT (cible non-N5 ?) — charge utile non recopiée, sortie 0"
            exit 0
          fi
          dev="$(readlink -f "$dev")"

          # Deux médias peuvent porter le même libellé : sans unicité on ne
          # devine pas laquelle amorce la carte (même refus que
          # `havenos payload`).
          if command -v blkid >/dev/null 2>&1; then
            labels="$(blkid -o device -t LABEL=NIXOS_BOOT 2>/dev/null | grep -c . || true)"
            if [ "''${labels:-0}" -gt 1 ]; then
              echo "nixelec-bootloader-hook : $labels partitions portent NIXOS_BOOT ; refus d'écrire" >&2
              exit 1
            fi
          fi

          # Écrire sur un disque entier recouvrirait le secteur 1 (FIP du
          # chargeur vendor) : on n'écrit que sur une partition.
          if [ "$(lsblk -dno TYPE "$dev" | head -n 1)" != part ]; then
            echo "nixelec-bootloader-hook : $dev n'est pas une partition ; refus d'écrire (secteur 1 jamais touché)" >&2
            exit 1
          fi

          # ── Montage ─────────────────────────────────────────────────────
          # En vendor, `NIXOS_BOOT` n'est pas montée : on la monte nous-mêmes
          # (jamais de montage en double). Le piège est de laisser la FAT
          # montée en écriture après un échec : d'où le démontage en `trap`.
          work="$(mktemp -d /tmp/nixelec-bootloader-hook.XXXXXX)"
          mnt="$(findmnt -no TARGET --source "$dev" 2>/dev/null | head -n 1 || true)"
          owned=0
          cleanup() {
            rc=$?
            if [ "$owned" -eq 1 ]; then
              sync 2>/dev/null || true
              umount "$mnt" 2>/dev/null || true
            fi
            rm -rf "$work"
            exit "$rc"
          }
          trap cleanup EXIT

          if [ -n "$mnt" ]; then
            case ",$(findmnt -no OPTIONS --source "$dev" | head -n 1)," in
              *,ro,*)
                echo "nixelec-bootloader-hook : NIXOS_BOOT est montée en lecture seule sur $mnt ; hook sans effet (la démonter pour qu'il écrive)"
                exit 0
                ;;
            esac
            echo "nixelec-bootloader-hook : NIXOS_BOOT déjà montée sur $mnt, écriture en place"
          else
            mnt="$work/mnt"
            mkdir -p "$mnt"
            mount -t vfat -o rw "$dev" "$mnt"
            owned=1
          fi

          # ── Idempotence ─────────────────────────────────────────────────
          # Si `init=` est déjà celui du toplevel et que les tailles
          # concordent, la charge utile est celle de cette génération : ne
          # rien écrire (et ne pas user la carte à chaque boot).
          payload_is_current() {
            for f in uEnv.ini s905_autoscript.txt emmc_autoscript.txt; do
              [ -f "$mnt/$f" ] || return 1
              got="$(sed -n 's/.*init=\([^ "]*\).*/\1/p' "$mnt/$f" | head -n 1)"
              [ "$got" = "$expected_init" ] || return 1
            done
            for f in Image initrd uImage uInitrd ${dtbBase}; do
              [ -s "$mnt/$f" ] || return 1
            done
            [ "$(stat -c %s "$mnt/Image")" -eq "$(stat -c %s "$toplevel/kernel")" ] || return 1
            [ "$(stat -c %s "$mnt/initrd")" -eq "$(stat -c %s "$toplevel/initrd")" ] || return 1
            [ "$(stat -c %s "$mnt/${dtbBase}")" -eq "$(stat -c %s "$toplevel/dtbs/${dtbName}")" ] || return 1
            return 0
          }

          if payload_is_current; then
            echo "nixelec-bootloader-hook : charge utile déjà à jour pour $toplevel (init= et tailles identiques) — rien écrit"
            exit 0
          fi

          # ── Reconstruction, hors FAT ────────────────────────────────────
          # Dans /tmp : une génération ratée ne laisse aucune trace sur la
          # partition, et rien n'est écrit tant que la charge utile n'est pas
          # complète (uImage/uInitrd compris).
          payload="$work/payload"
          mkdir -p "$payload"
          cp -L "$toplevel/kernel" "$payload/Image"
          cp -L "$toplevel/initrd" "$payload/initrd"
          cp -L "$toplevel/dtbs/${dtbName}" "$payload/${dtbBase}"

          # `kernel-params` est le fichier du toplevel : la console, le CMA et
          # le mode vidéo sont ceux que ce noyau recevra réellement, pas ceux
          # supposés par un autre build.
          bootargs="$(cat "$toplevel/kernel-params") earlycon root=LABEL=${rootLabel} rootwait rw init=$expected_init"
          printf 'dtb_name=/%s\nbootargs=%s\n' "${dtbBase}" "$bootargs" > "$payload/uEnv.ini"

          # Un autoscript par média, épinglé à son numéro de mmc : le vendor
          # numérote la SD `mmc 0` et la eMMC `mmc 1`. Aucun repli — un script
          # qui tente les deux médias a déjà chargé la charge utile de la SD en
          # démarrant depuis la eMMC (cause mesurée le 31/10).
          for mmc in 0 1; do
            {
              printf 'setenv bootargs "%s"\n' "$bootargs"
              printf 'setenv uimage_addr 0x20000000\n'
              printf 'setenv uinitrd_addr 0x13000000\n'
              printf 'setenv fdt_addr 0x1000000\n'
              printf 'fatload mmc %s:1 ''${uimage_addr} uImage\n' "$mmc"
              printf 'fatload mmc %s:1 ''${uinitrd_addr} uInitrd\n' "$mmc"
              printf 'fatload mmc %s:1 ''${fdt_addr} %s\n' "$mmc" "${dtbBase}"
              printf 'echo "Booting NixOS from mmc %s:1"\n' "$mmc"
              printf 'bootm ''${uimage_addr} ''${uinitrd_addr} ''${fdt_addr}\n'
            } > "$payload/autoscript-mmc$mmc.txt"
          done
          cp "$payload/autoscript-mmc0.txt" "$payload/s905_autoscript.txt"
          cp "$payload/autoscript-mmc1.txt" "$payload/emmc_autoscript.txt"

          ${pkgs.ubootTools}/bin/mkimage -A arm64 -O linux -T script -C none -n "N5 boot SD" \
            -d "$payload/s905_autoscript.txt" "$payload/s905_autoscript"
          ${pkgs.ubootTools}/bin/mkimage -A arm64 -O linux -T script -C none -n "N5 boot eMMC" \
            -d "$payload/emmc_autoscript.txt" "$payload/emmc_autoscript"
          # `bootm` refuse un initrd cpio brut, d'où `uInitrd` encapsulé ; et
          # le chargeur relit mal au-delà de ~38 Mo (mesuré : `Bad Data CRC`
          # sur un conteneur de 63 Mo), d'où deux fichiers séparés.
          ${pkgs.ubootTools}/bin/mkimage -A arm64 -O linux -T kernel -C none -a 0x1080000 -e 0x1080000 \
            -n NixOS -d "$payload/Image" "$payload/uImage"
          ${pkgs.ubootTools}/bin/mkimage -A arm64 -O linux -T ramdisk -C gzip -n "NixOS initrd" \
            -d "$payload/initrd" "$payload/uInitrd"

          files="Image initrd ${dtbBase} uImage uInitrd s905_autoscript emmc_autoscript s905_autoscript.txt emmc_autoscript.txt uEnv.ini"
          ( cd "$payload" && sha256sum $files > "$work/manifest" )

          # `cp -f` tronque les fichiers existants : leur place est donc
          # récupérable, mais seulement au fil de l'écriture. On compte cette
          # place avant de refuser, sinon une mise à jour sur une partition
          # déjà remplie par l'ancienne charge utile serait rejetée à tort.
          need=$(du -sb "$payload" | cut -f1)
          avail=$(df -B1 --output=avail "$mnt" | tail -n 1 | tr -d ' ')
          reclaim=0
          for f in $files; do
            if [ -f "$mnt/$f" ]; then
              reclaim=$((reclaim + $(stat -c %s "$mnt/$f")))
            fi
          done
          margin=8388608
          if [ -z "$avail" ] || [ $((avail + reclaim)) -lt $((need + margin)) ]; then
            echo "nixelec-bootloader-hook : place insuffisante sur NIXOS_BOOT : ''${avail:-0} octets libres + $reclaim récupérables, $need + $margin requis ; rien n'est écrit" >&2
            exit 1
          fi

          # Ordre d'écriture : noyau et initrd d'abord, scripts d'amorçage en
          # dernier. Une coupure en plein transfert laisse alors les anciens
          # scripts en place, qui désignent une fermeture déjà présente : au
          # pire l'ancien système démarre, jamais un `init=` absent du store.
          for f in Image initrd ${dtbBase} uImage uInitrd; do
            cp -fL "$payload/$f" "$mnt/$f"
          done
          for f in s905_autoscript.txt emmc_autoscript.txt uEnv.ini; do
            cp -fL "$payload/$f" "$mnt/$f"
          done
          for f in s905_autoscript emmc_autoscript; do
            cp -fL "$payload/$f" "$mnt/$f"
          done
          # Pas de `boot.scr` : le bootcmd du U-Boot vendor charge
          # explicitement `s905_autoscript` / `emmc_autoscript` (mmc 0 / mmc 1),
          # et le BL33 mainline ne le lit qu'en repli APRÈS
          # `extlinux/extlinux.conf` — une charge utile figée y serait un piège
          # le jour de la migration. Même choix que `platform_write_boot`.
          sync

          # ── Relecture hors cache, puis sha256 ───────────────────────────
          if [ "$owned" -eq 1 ]; then
            umount "$mnt"
            mount -t vfat -o ro "$dev" "$mnt"
          else
            # Montage préexistant : on ne peut pas démonter, mais il faut
            # pousser au média avant de comparer — sinon `sha256sum` valide le
            # page cache de l'écriture (défaut déjà constaté sur cette carte).
            blockdev --flushbufs "$dev" 2>/dev/null || true
            echo 3 > /proc/sys/vm/drop_caches
          fi

          if ! ( cd "$mnt" && sha256sum -c "$work/manifest" ); then
            echo "nixelec-bootloader-hook : relecture différente de l'écrit sur NIXOS_BOOT ; la charge utile n'est pas fiable" >&2
            exit 1
          fi

          # `init=` relu dans chaque source lisible, pas seulement déduit des
          # sha256 : c'est la seule preuve que la carte amorcera bien CE
          # toplevel.
          for f in uEnv.ini s905_autoscript.txt emmc_autoscript.txt; do
            got="$(sed -n 's/.*init=\([^ "]*\).*/\1/p' "$mnt/$f" | head -n 1)"
            if [ "$got" != "$expected_init" ]; then
              echo "nixelec-bootloader-hook : $f porte init='$got', attendu '$expected_init'" >&2
              exit 1
            fi
          done

          echo "nixelec-bootloader-hook : charge utile réécrite sur NIXOS_BOOT (10 fichiers), init=$expected_init"
        '';
      };
    })
  ];
}
