# Microcodes du VPU Amlogic (meson-amvdec).
#
# Le driver les charge via request_firmware() — `meson/vdec/gxl_h264_multi.bin`
# pour H.264 sur GXL — et ils ne sont PAS dans linux-firmware.
#
# Licence Amlogic (le LICENSE amont est recopié dans la sortie) : usage et
# redistribution autorisés pour les appareils à puce Amlogic, mais pas dans
# l'arbre du noyau ni sous GPL. D'où un paquet firmware séparé, jamais fusionné
# à la dérivation du noyau.
#
# Sans ce module, le décodage matériel échoue silencieusement côté application :
# ffmpeg renvoie `Invalid data found when processing input`, et seul `dmesg`
# nomme la cause (`Direct firmware load for meson/vdec/… failed with error -2`).
{ config, lib, pkgs, ... }:

let
  cfg = config.nixelec.vdecFirmware;

  mesonVdecFirmware = pkgs.runCommand "meson-vdec-firmware" {
    src = pkgs.fetchFromGitHub {
      owner = "LibreELEC";
      repo = "meson-firmware";
      rev = "662b843714ac18e92b19887fadc8d8b3d94fc814";
      hash = "sha256-EvjVUPbTdDFHyM/RL2suaY33lfGbj/pa96UXWI7Jfsw=";
    };
  } ''
    mkdir -p $out/lib/firmware/meson/vdec
    cp $src/meson/vdec/*.bin $out/lib/firmware/meson/vdec/
    install -Dm644 $src/LICENSE $out/lib/firmware/meson/vdec/LICENSE.amlogic
  '';
in
{
  options.nixelec.vdecFirmware.enable = lib.mkEnableOption ''
    les microcodes du VPU Amlogic dans le firmware du système
  '';

  config = lib.mkIf cfg.enable {
    nixelec.extraFirmware = [ mesonVdecFirmware ];
  };
}
