{
  coreutils,
  diffutils,
  findutils,
  gawk,
  git,
  gnugrep,
  gnused,
  writeShellApplication,
}:

writeShellApplication {
  name = "stamps";
  runtimeInputs = [
    coreutils
    diffutils
    findutils
    gawk
    git
    gnugrep
    gnused
  ];
  text = builtins.readFile ../dev/stamps.sh;
}
