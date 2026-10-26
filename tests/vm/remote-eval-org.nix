# tests/vm/remote-eval-org.nix
#
# The org's flake.nix in tests/vm/remote-eval.nix: a stage whose build says which o11n and
# private input it got, one that fails, one that writes a report and one that takes its time.
{
  inputs = {
    o11n.url = "git+file:///srv/o11n";
    private.url = "git+ssh://git@localhost/srv/private";
  };

  outputs =
    { o11n, private, ... }:
    let
      stage =
        name: script:
        derivation {
          name = "stage-${name}";
          system = "x86_64-linux";
          builder = "/bin/sh";
          args = [
            "-c"
            script
          ];
        };
    in
    {
      stages = {
        ok = stage "ok" "echo o11n ${o11n.value}, ${private.value}; echo > $out";
        fails = stage "fails" "echo failing; exit 3";
        report = stage "report" "echo reported >$out";
        # Fact: the sandbox's /bin/sh has no sleep.
        slow = stage "slow" "while :; do :; done";
      };
    };
}
