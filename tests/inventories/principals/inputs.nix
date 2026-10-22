# Flakes often export a module as an inline function, which takes pkgs from _module.args.
{
  test-input.nixosModules.default =
    { pkgs, ... }:
    {
      environment.etc."test-input".text = pkgs.hello.pname;
    };
}
