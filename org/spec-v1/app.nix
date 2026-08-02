{
  config,
  context,
  lib,
  ...
}:
{
  imports = [
    ./entity.nix
  ];

  config = {
    class = "app";
  };

  options = {
    endpoint = lib.mkOption {
      description = "canonical name on internet";
      type = lib.types.str;
    };
    url = lib.mkOption {
      description = "public url including scheme";
      default = "${config.scheme}://${config.endpoint}";
      type = lib.types.str;
    };
    location = lib.mkOption {
      description = "canonical path";
      default = "/";
      type = lib.types.str;
    };
    configurationFile = lib.mkOption {
      description = "path to specific configuration";
      type = lib.types.coercedTo lib.types.str (s: context.path + "/${s}") lib.types.path;
      default = "apps/${config.name}.nix";
    };
    altpoints = lib.mkOption {
      description = "alternative access points that should be redirected to endpoint";
      default = [ ];
      type = with lib.types; listOf str;
    };
    run-on-hosts = lib.mkOption {
      description = "hosts that this app should run on";
      type = with lib.types; listOf str;
    };
    database = lib.mkOption {
      description = "app's database";
      default = config.name;
      type = lib.types.str;
    };
    ssl = lib.mkOption {
      description = "let's encrypt and force https";
      default = true;
      type = lib.types.bool;
    };
    scheme = lib.mkOption {
      description = "http or https";
      default = if config.ssl then "https" else "http";
      type = lib.types.str;
    };
  };
}
