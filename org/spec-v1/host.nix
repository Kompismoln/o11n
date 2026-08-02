# org/spec-v1/host.nix
{
  lib,
  config,
  context,
  ...
}:
{
  imports = [
    ../host.nix
  ];

  options =
    let
      networkModule = lib.types.submodule {
        imports = [ ../network.nix ];
        _module.args.context = context;
      };

      diskLayoutModule = lib.types.submodule {
        imports = [ ../diskLayout.nix ];
        _module.args.context = context;
      };

      homeModule = lib.types.submodule {
        imports = [ ../home.nix ];
        _module.args = {
          host = config;
          inherit context;
        };
      };
    in
    {
      eth = lib.mkOption {
        type = lib.types.nullOr networkModule;
        default = null;
        description = "ethernet network";
      };
      wifi = lib.mkOption {
        type = lib.types.nullOr networkModule;
        default = null;
        description = "wifi network";
      };
      extraNetworks = lib.mkOption {
        type = lib.types.listOf networkModule;
        default = [ ];
        description = "extra networks";
      };
      homes = lib.mkOption {
        type = lib.types.attrsOf homeModule;
        default = { };
        description = "list of home configurations for a user";
      };
      diskLayouts = lib.mkOption {
        type = lib.types.attrsOf diskLayoutModule;
        default = { };
        description = "record of disk layouts that applies to host";
      };
      users = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "users";
      };
      roles = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "roles";
      };
      vpns = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "vpns";
      };
    };
}
