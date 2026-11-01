{
  pkgs,
  o11n,
  o11n-dev,
  testExport,
}:
let
  inherit (pkgs) lib;
  inherit (lib) fileset;

  root = ../.;
  source =
    files:
    fileset.toSource {
      inherit root;
      fileset = files;
    };
  shell =
    f:
    lib.any f.hasExt [
      "sh"
      "bash"
      "bats"
    ];

  md = fileset.fileFilter (f: f.hasExt "md") root;
  nix = fileset.fileFilter (f: f.hasExt "nix") root;

  # Optimization: a stage of dev/check.sh sees only the files it reads, so that nix runs it again only
  # when one of them changes.
  stage =
    name: files: inputs:
    pkgs.runCommand name
      {
        src = source (
          fileset.unions (
            [
              ../dev/check.sh
            ]
            ++ files
          )
        );
        nativeBuildInputs = [ o11n-dev ] ++ inputs;
      }
      ''
        cp -r $src src
        chmod -R u+w src
        patchShebangs src
        cd src
        bash dev/check.sh ${name}
        touch $out
      '';
in
{
  stamps =
    stage "stamps"
      [
        md
      ]
      [ ];

  format =
    stage "format"
      [
        md
        nix
        (fileset.fileFilter (f: f.hasExt "rs") root)
        ../.prettierrc.yaml
        ../rustfmt.toml
      ]
      [
        pkgs.nixfmt
        pkgs.prettier
        pkgs.rustfmt
      ];

  lint =
    stage "lint"
      [
        (fileset.fileFilter (f: f.hasExt "nix" || shell f) root)
        ../statix.toml
        ../crates/o11n/test
      ]
      [
        pkgs.deadnix
        pkgs.shellcheck
        pkgs.statix
      ];

  bats =
    pkgs.runCommand "bats"
      {
        src = source (
          fileset.unions [
            ../.prettierrc.yaml
            ../dev
            ../nixos/org/locksmith.sh
            ../crates/o11n/test
            ../settings.toml
          ]
        );
        nativeBuildInputs = [
          pkgs.age
          pkgs.bats
          pkgs.git
          pkgs.jq
          pkgs.nix
          pkgs.nixfmt
          o11n
          o11n-dev
          pkgs.openssh
          pkgs.prettier
          pkgs.rustfmt
          pkgs.socat
          pkgs.sops
          pkgs.tree
          pkgs.util-linux
        ];
      }
      ''
        cp -r $src src
        chmod -R u+w src
        patchShebangs src
        export HOME=$TMPDIR O11N_TEST_EXPORT=${testExport}
        export NIX_CONFIG='experimental-features = nix-command'
        bats src/crates/o11n/test src/dev/test
        touch $out
      '';
}
