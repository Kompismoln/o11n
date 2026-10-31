# Accommodating for the scripts of dev/, which read what they source from the clone's root: each
# package runs from there, as dev/<name>.sh does.
{
  coreutils,
  deadnix,
  diffutils,
  findutils,
  gawk,
  git,
  gnugrep,
  gnused,
  jq,
  lib,
  nixfmt,
  o11n-tools,
  prettier,
  shellcheck,
  statix,
  toml2json,
  util-linux,
  writeShellApplication,
}:
let
  script =
    name: runtimeInputs:
    writeShellApplication {
      inherit name runtimeInputs;
      text = builtins.readFile ../dev/${name}.sh;
      excludeShellChecks = [ "SC1091" ];
      passthru = { inherit runtimeInputs; };
    };

  shell = [
    coreutils
    findutils
    gawk
    git
    gnugrep
    gnused
  ];
  stamps = shell ++ [ diffutils ];
  write = stamps ++ [
    jq
    nixfmt
    prettier
  ];
  check =
    write
    ++ [
      deadnix
      shellcheck
      statix
      toml2json
    ]
    ++ o11n-tools.runtimeInputs;
  fetch-inputs = shell ++ [ jq ];
in
lib.mapAttrs script {
  inherit
    stamps
    write
    check
    fetch-inputs
    ;
  agent = lib.unique (check ++ fetch-inputs ++ [ jq ]);
  operator = check;
  lix-daemon = shell ++ [ util-linux ];
}
