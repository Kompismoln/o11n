{ lib, ... }:
{
  imports = [
    ./entity.nix
  ];

  config = {
    class = "user";
  };

  options = {
    email = lib.mkOption {
      description = "user's email address";
      default = null;
      type = with lib.types; nullOr str;
    };
  };
}
