{
  clippy,
  lib,
  rustPlatform,
}:
rustPlatform.buildRustPackage {
  pname = "o11n";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../Cargo.toml
      ../Cargo.lock
      ../crates
    ];
  };
  cargoLock.lockFile = ../Cargo.lock;

  nativeCheckInputs = [ clippy ];
  preCheck = ''
    cargo clippy --offline --all-targets -- --deny warnings
  '';

  meta.mainProgram = "o11n";
}
