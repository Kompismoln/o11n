{
  curl,
  gost,
  lib,
  makeWrapper,
  o11n,
  openssh,
  sops,
  stdenv,
  ...
}:

let
  runtimeInputs = [
    curl
    gost
    o11n
    openssh
    sops
  ];
in
stdenv.mkDerivation {
  pname = "o11n-tools";
  inherit (o11n) version;
  dontUnpack = true;

  nativeBuildInputs = [ makeWrapper ];

  passthru = { inherit runtimeInputs; };

  installPhase = ''
    runHook preInstall
    makeWrapper ${lib.getExe o11n} $out/bin/o11n \
      --set-default O11N_ORG_ROOT /etc/nix/inputs/self \
      --prefix PATH : ${lib.makeBinPath runtimeInputs}
    runHook postInstall
  '';

  meta.mainProgram = "o11n";
}
