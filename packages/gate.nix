{
  clippy,
  lib,
  rustPlatform,
}:
rustPlatform.buildRustPackage {
  pname = "gate";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ../crates/gate;
    fileset = lib.fileset.unions [
      ../crates/gate/Cargo.toml
      ../crates/gate/Cargo.lock
      ../crates/gate/src
    ];
  };
  cargoLock.lockFile = ../crates/gate/Cargo.lock;

  nativeCheckInputs = [ clippy ];
  preCheck = ''
    cargo clippy --offline --all-targets -- --deny warnings
  '';

  meta.mainProgram = "gate";
}
