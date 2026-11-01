{
  clippy,
  lib,
  rustPlatform,
}:
rustPlatform.buildRustPackage {
  pname = "o11n-dev";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ../crates/o11n-dev;
    fileset = lib.fileset.unions [
      ../crates/o11n-dev/Cargo.toml
      ../crates/o11n-dev/Cargo.lock
      ../crates/o11n-dev/src
    ];
  };
  cargoLock.lockFile = ../crates/o11n-dev/Cargo.lock;

  nativeCheckInputs = [ clippy ];
  preCheck = ''
    cargo clippy --offline --all-targets -- --deny warnings
  '';

  meta.mainProgram = "o11n-dev";
}
