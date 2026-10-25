_: prev: {
  python313Packages = prev.python313Packages.overrideScope (
    pyFinal: _: {
      xgrammar = pyFinal.callPackage ../packages/xgrammar.nix { };
    }
  );
}
