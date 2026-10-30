{
  python3,
  fetchFromGitHub,
  writeShellScriptBin,
  runCommand,
}:

# pyamlboot n'est pas dans nixpkgs. C'est l'utilitaire du protocole USB BootROM
# Amlogic (MaskROM) : `boot.py` charge un U-Boot en RAM, `bulkcmd.py` envoie des
# commandes au chargeur déjà démarré.
#
# `boot.py` localise ses fichiers par `pkg_resources.get_distribution(...)` puis
# `get_resource_filename(..., "files")`, c'est-à-dire à la racine de la
# distribution — pas dans le paquet Python. On génère donc les métadonnées dans
# l'arbre et on l'expose tel quel via PYTHONPATH, plutôt que d'installer un
# paquet dont la disposition ne correspondrait pas à ce que le script attend.
let
  src = fetchFromGitHub {
    owner = "superna9999";
    repo = "pyamlboot";
    rev = "d2857f4371bcdb7a90d885f24987e03b6d647a8a";
    hash = "sha256-ewPSd+rwzE3m5ex7MUTW3J89vNkdBIOGhlpH7rFa5HM=";
  };

  pythonEnv = python3.withPackages (ps: [
    ps.setuptools # setup.py egg_info
    ps.pyusb # protocole USB de la BootROM
  ]);

  tree = runCommand "pyamlboot-unstable-2026-03-26" { nativeBuildInputs = [ pythonEnv ]; } ''
    cp -r ${src}/. $out
    chmod -R u+w $out
    cd $out
    python3 setup.py egg_info >/dev/null
  '';
in
{
  inherit tree;

  # `amlboot <carte> --image …` : charge un binaire en RAM via la BootROM.
  # Aucune écriture sur un média, donc rien ne peut être brické.
  amlboot = writeShellScriptBin "amlboot" ''
    export PYTHONPATH=${tree}:$PYTHONPATH
    exec ${pythonEnv}/bin/python3 ${tree}/boot.py "$@"
  '';

  # Commandes bulk vers un chargeur déjà en RAM (après `amlboot`).
  amlbulk = writeShellScriptBin "amlbulk" ''
    export PYTHONPATH=${tree}:$PYTHONPATH
    exec ${pythonEnv}/bin/python3 ${tree}/bulkcmd.py "$@"
  '';

  # Identification du SoC tel que vu par la BootROM.
  amlsocid = writeShellScriptBin "amlsocid" ''
    export PYTHONPATH=${tree}:$PYTHONPATH
    exec ${pythonEnv}/bin/python3 ${tree}/socid.py "$@"
  '';
}
