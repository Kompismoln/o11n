{ lib, ... }:
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
    data = lib.mkOption {
      description = "arbitrary data to service";
      type = with lib.types; attrsOf anything;
    };
  };
}
