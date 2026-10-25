{
  coreutils,
  gawk,
  git,
  jq,
  symlinkJoin,
  writeShellApplication,
}:

let
  script =
    name:
    writeShellApplication {
      inherit name;
      runtimeInputs = [
        coreutils
        gawk
        git
        jq
      ];
      text = builtins.readFile ../scripts/${name};
    };
in
symlinkJoin {
  name = "o11n-scripts";
  paths = map script [
    "fetch.sh"
    "stamp.sh"
    "merge.sh"
    "check-org.sh"
  ];
}
