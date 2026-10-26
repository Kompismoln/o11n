# nixos/org/home-manager.nix
{
  host,
  inputs,
  o11nInputs,
  lib,
  org,
  pkgs,
  ...
}:
{
  imports = [
    o11nInputs.home-manager.nixosModules.home-manager
  ];

  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    extraSpecialArgs = {
      inherit inputs o11nInputs org;
    };
    users = lib.mapAttrs (_: home: {
      _module.args.home = home;

      home.packages = [ pkgs.home-manager ];

      imports = [
        home.configurationFile
      ]
      ++ map (role: o11nInputs.self.homeModules.${role}) home.roles;
    }) org.host.${host.name}.home;
  };
}
