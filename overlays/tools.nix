final: _: {
  o11n-tools = final.callPackage ../packages/o11n-tools.nix { };
  origin = final.callPackage ../packages/origin.nix { };
}
