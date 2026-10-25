# overlays/tokenspeed-triton-nanobind-fix.nix
_: prev: {
  python313Packages = prev.python313Packages.overrideScope (
    _: pyPrev: {
      flashinfer = pyPrev.flashinfer.overridePythonAttrs (_: {
        pname = "flashinfer-python";
      });
      tokenspeed-triton = pyPrev.tokenspeed-triton.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          substituteInPlace CMakeLists.txt \
          --replace-fail \
            'add_library(Python::Module ALIAS Python3::Module)' \
            'add_library(Python::Module ALIAS Python3::Module)
          add_executable(Python::Interpreter ALIAS Python3::Interpreter)'
        '';
      });
    }
  );
}
