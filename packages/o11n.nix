{
  clippy,
  curl,
  gost,
  lib,
  makeWrapper,
  openssh,
  rustPlatform,
  sops,
}:
let
  runtimeInputs = [
    curl
    gost
    openssh
    sops
  ];
in
rustPlatform.buildRustPackage {
  pname = "o11n";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../Cargo.toml
      ../Cargo.lock
      (lib.fileset.difference ../crates/o11n ../crates/o11n/test)
    ];
  };
  cargoLock.lockFile = ../Cargo.lock;

  nativeBuildInputs = [ makeWrapper ];
  nativeCheckInputs = [ clippy ];
  preCheck = ''
    cargo clippy --offline --all-targets -- --deny warnings
  '';

  # Policy: after what's on PATH, so that a test's stubs stand in for them.
  postInstall = ''
    wrapProgram $out/bin/o11n --suffix PATH : ${lib.makeBinPath runtimeInputs}
  '';

  passthru = { inherit runtimeInputs; };

  meta.mainProgram = "o11n";
}
