{
  coreutils,
  gawk,
  git,
  jq,
  writeShellApplication,
}:

writeShellApplication {
  name = "operator";
  runtimeInputs = [
    coreutils
    gawk
    git
    jq
  ];
  text = builtins.readFile ../dev/operator.sh;
}
