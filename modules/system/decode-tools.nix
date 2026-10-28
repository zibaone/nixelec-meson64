# Outils de qualification du VPU stateless, pour une image de test dédiée.
#
# La cible de bring-up est volontairement minimale (pas de Nix, pas de ffmpeg).
# Ce module ajoute ce qu'il faut pour *mesurer* un décodage — v4l2-ctl pour
# énumérer les formats, ffmpeg construit avec --enable-v4l2-request pour
# exécuter `h264_v4l2request` — et un échantillon H.264 1080p reproductible.
#
# L'échantillon est encodé à la construction par un ffmpeg doté de libx264 qui
# tourne sur la machine de build : la cible n'a aucun encodeur, et committer un
# binaire de plusieurs Mio dans le dépôt serait pire.
{ config, lib, pkgs, ... }:

let
  cfg = config.nixelec.decodeTools;

  sample = pkgs.runCommand "n5-h264-1080p-sample" {
    nativeBuildInputs = [ cfg.sampleEncoder ];
  } ''
    mkdir -p $out
    ffmpeg -hide_banner -loglevel error \
      -f lavfi -i "testsrc2=size=1920x1080:rate=30:duration=6" \
      -c:v libx264 -profile:v high -level 4.1 -pix_fmt yuv420p \
      -b:v 4M -g 60 -threads 1 \
      -x264-params "keyint=60:min-keyint=60:scenecut=0" \
      -fflags +bitexact -flags +bitexact \
      "$out/sample-1080p.h264"
    ls -l "$out/sample-1080p.h264"
  '';

in
{
  options.nixelec.decodeTools = {
    enable = lib.mkEnableOption "les outils de qualification du VPU (v4l-utils, ffmpeg v4l2-request)";

    ffmpeg = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = "ffmpeg construit avec `--enable-v4l2-request`.";
    };

    sampleEncoder = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      description = ''
        ffmpeg doté de libx264, exécuté sur la machine de build (x86_64) pour
        produire l'échantillon de test.
      '';
    };
  };

  imports = [ ./vdec-firmware.nix ];

  config = lib.mkIf cfg.enable {
    # Sans ces microcodes le VPU ne démarre pas : request_firmware() échoue et
    # le décodage tombe, quel que soit l'état du reste de la chaîne.
    nixelec.vdecFirmware.enable = true;

    environment.systemPackages =
      [ pkgs.v4l-utils ]
      ++ lib.optional (cfg.ffmpeg != null) cfg.ffmpeg;

    # Mesure reproductible : logiciel vs hwaccel. `-benchmark` donne utime/stime,
    # qui sont le seul moyen honnête de distinguer un décodage matériel d'un
    # décodage logiciel qui « réussit » aussi.
    #
    # NB : le sélecteur CLI est `-hwaccel drm`, PAS `-hwaccel v4l2request`.
    # Le hwaccel est nommé `h264_v4l2request` dans le registre mais ffmpeg ne le
    # résout pas par ce nom ; il passe par la hw config DRM_PRIME/DRM.
    environment.etc =
      lib.optionalAttrs (cfg.sampleEncoder != null) {
        "n5/samples/sample-1080p.h264".source = "${sample}/sample-1080p.h264";
      }
      // lib.optionalAttrs (cfg.ffmpeg != null) {
        "n5/decode-test.sh".source = pkgs.writeShellScript "n5-decode-test" ''
          set -u
          S=/etc/n5/samples/sample-1080p.h264
          N=5

          echo "=== devices ==="
          v4l2-ctl --list-devices
          echo
          echo "=== formats (OUTPUT = codé) ==="
          v4l2-ctl -d /dev/video0 --list-formats-out
          echo
          echo "=== software decode, $N runs (contrôle) ==="
          for i in $(seq $N); do
            ffmpeg -hide_banner -nostats -loglevel info -benchmark \
              -c:v h264 -i "$S" -f null - 2>&1 | grep -a bench
          done
          echo
          echo "=== v4l2request via -hwaccel drm, $N runs ==="
          for i in $(seq $N); do
            ffmpeg -hide_banner -nostats -loglevel info -benchmark \
              -hwaccel drm -c:v h264 -i "$S" -f null - 2>&1 | grep -aE "bench|Failed"
          done
          echo
          echo "If the hw path fails, re-run one iteration without -loglevel error:"
          echo "  ffmpeg -hwaccel drm -c:v h264 -i $S -f null -"
        '';
      };
  };
}
