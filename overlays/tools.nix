final: _: {
  o11n = final.callPackage ../packages/o11n.nix { };
  o11n-tools = final.callPackage ../packages/o11n-tools.nix { };
  origin = final.callPackage ../packages/origin.nix { };
}
