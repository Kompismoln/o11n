{ pkgs }:
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
              ../dev/files.bash
            ]
            ++ files
          )
        );
        nativeBuildInputs = inputs;
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
        ../dev/stamps.sh
      ]
      [ ];

  format =
    stage "format"
      [
        md
        nix
        ../.prettierrc.yaml
      ]
      [
        pkgs.nixfmt
        pkgs.prettier
      ];

  lint =
    stage "lint"
      [
        (fileset.fileFilter (f: f.hasExt "nix" || shell f) root)
        ../statix.toml
        ../tools
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
            ../tools
          ]
        );
        nativeBuildInputs = [
          pkgs.age
          pkgs.bats
          pkgs.gettext
          pkgs.git
          pkgs.jq
          pkgs.mkpasswd
          pkgs.nix
          pkgs.nixfmt
          pkgs.openssh
          pkgs.openssl
          pkgs.prettier
          pkgs.python3
          pkgs.sops
          pkgs.toml2json
          pkgs.tree
          pkgs.util-linux
          pkgs.wireguard-tools
        ];
      }
      ''
        cp -r $src src
        chmod -R u+w src
        patchShebangs src
        export HOME=$TMPDIR
        export NIX_CONFIG='experimental-features = nix-command'
        bats src/tools/test src/dev/test
        touch $out
      '';
}
