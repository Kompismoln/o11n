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
  o11n,
  o11n-dev,
  prettier,
  rustfmt,
  shellcheck,
  statix,
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
  write = shell ++ [
    diffutils
    jq
    nixfmt
    o11n-dev
    prettier
    rustfmt
  ];
  check =
    write
    ++ [
      deadnix
      shellcheck
      statix
    ]
    ++ [ o11n ]
    ++ o11n.runtimeInputs;
in
lib.mapAttrs script {
  inherit write check;
  agent = lib.unique (check ++ [ util-linux ]);
  operator = check;
}
