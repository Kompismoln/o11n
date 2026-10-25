# tests/source.nix
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

  stamps = pkgs.callPackage ../packages/stamps.nix { };
in
{
  lint =
    pkgs.runCommand "lint"
      {
        src = source (
          fileset.unions [
            (fileset.fileFilter (f: f.hasExt "nix" || shell f) root)
            ../statix.toml
            ../tools
          ]
        );
        nativeBuildInputs = [
          pkgs.deadnix
          pkgs.nixfmt
          pkgs.shellcheck
          pkgs.statix
        ];
      }
      ''
        cd $src
        find . -name '*.nix' -print0 | xargs -0 nixfmt --check
        statix check .
        deadnix --fail .
        # Accommodating for tools/.shellcheckrc, whose source path is relative to tools/.
        find . -path ./tools -prune -o -type f \( -name '*.sh' -o -name '*.bash' -o -name '*.bats' \) -print0 |
          xargs -0 shellcheck -s bash
        (cd tools && find . -type f \( -path './test/bin/*' -o -name '*.sh' -o -name '*.bash' -o -name '*.bats' \) -print0 |
          xargs -0 shellcheck -s bash)
        touch $out
      '';

  bats =
    pkgs.runCommand "bats"
      {
        src = source (
          fileset.unions [
            ../dev
            ../nixos/org/locksmith.sh
            ../scripts
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
          pkgs.openssh
          pkgs.openssl
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
        bats src/tools/test src/dev/test src/scripts/test
        touch $out
      '';

  stamps = pkgs.runCommand "stamps" { } ''
    ${lib.getExe stamps} check ${source (fileset.fileFilter (f: f.hasExt "md") root)}
    touch $out
  '';
}
