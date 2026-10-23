# tests/vm/stand-in.nix
# A host's system in the operator's stand-in for the org's flake: only the tooling sees it.
name:
derivation {
  inherit name;
  system = "x86_64-linux";
  builder = "/bin/sh";
  args = [
    "-c"
    "echo ${name} > $out"
  ];
}
