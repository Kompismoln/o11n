final: prev: {
  python313Packages = prev.python313Packages.overrideScope (
    pyFinal: pyPrev: {
      xgrammar = pyFinal.callPackage ../packages/xgrammar.nix { };
    }
  );
}
