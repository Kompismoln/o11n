{
  age,
  curl,
  gost,
  jq,
  lib,
  makeWrapper,
  mkpasswd,
  openssh,
  openssl,
  shellcheck,
  sops,
  stdenv,
  o11n,
  wireguard-tools,
  ...
}:

let
  runtimeInputs = [
    age
    curl
    gost
    jq
    mkpasswd
    openssl
    o11n
    openssh
    sops
    wireguard-tools
  ];
in
stdenv.mkDerivation {
  pname = "o11n-tools";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ../tools;
    fileset = lib.fileset.difference ../tools ../tools/test;
  };

  nativeBuildInputs = [
    makeWrapper
    shellcheck
  ];

  passthru = { inherit runtimeInputs; };

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    find bin libexec -type f -print0 | xargs -0 shellcheck
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -a ./ $out

    patchShebangs $out/bin $out/libexec

    for script in $out/bin/*; do
      wrapProgram "$script" \
        --set-default O11N_ORG_ROOT /etc/nix/inputs/self \
        --prefix PATH : ${lib.makeBinPath runtimeInputs}
    done
    runHook postInstall
  '';
}
