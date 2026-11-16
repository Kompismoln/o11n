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

  # Optimization: the tests of o11n and those of dev/ are a job each, so that a change to one leaves the other built.
  bats = {
    bats-o11n =
      pkgs.runCommand "bats-o11n"
        {
          src = source (
            fileset.unions [
              ../nixos/services/locksmith.sh
              ../nixos/services/torrent-server.sh
              ../crates/o11n/test
            ]
          );
          nativeBuildInputs = [
            pkgs.age
            pkgs.bats
            pkgs.git
            pkgs.jq
            pkgs.libarchive
            pkgs.nix
            o11n
            pkgs.openssh
            pkgs.socat
            pkgs.sops
            pkgs.util-linux
          ];
        }
        ''
          cp -r $src src
          chmod -R u+w src
          patchShebangs src
          export HOME=$TMPDIR O11N_TEST_EXPORT=${testExport}
          export NIX_CONFIG='experimental-features = nix-command'
          bats src/crates/o11n/test
          touch $out
        '';

    bats-dev =
      pkgs.runCommand "bats-dev"
        {
          src = source (
            fileset.unions [
              ../.prettierrc.yaml
              ../dev
            ]
          );
          nativeBuildInputs = [
            pkgs.bats
            pkgs.git
            pkgs.jq
            pkgs.nix
            pkgs.nixfmt
            o11n-dev
            pkgs.prettier
            pkgs.rustfmt
            pkgs.socat
            pkgs.util-linux
          ];
        }
        ''
          cp -r $src src
          chmod -R u+w src
          patchShebangs src
          export HOME=$TMPDIR
          export NIX_CONFIG='experimental-features = nix-command'
          bats src/dev/test
          touch $out
        '';
  };
}
