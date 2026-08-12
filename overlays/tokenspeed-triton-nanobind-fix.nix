# overlays/tokenspeed-triton-nanobind-fix.nix
final: prev: {
  python313Packages = prev.python313Packages.overrideScope (
    pyFinal: pyPrev: {
      flashinfer = pyPrev.flashinfer.overridePythonAttrs (old: {
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
