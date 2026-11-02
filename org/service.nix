{ lib, context, ... }:
{
  imports = [
    ./entity.nix
  ];

  config = {
    class = "service";
  };

  options = {
    endpoint = lib.mkOption {
      description = "maybe canonical name on internet";
      default = null;
      type = with lib.types; nullOr str;
    };
    vpn = lib.mkOption {
      description = "the vpn the service serves on, at its address on each host it's on, or null";
      default = null;
      type = lib.types.nullOr context.types.vpn.ref;
    };
    data = lib.mkOption {
      description = "arbitrary data to service";
      type = with lib.types; attrsOf anything;
    };
  };
}
