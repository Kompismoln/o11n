{ lib, ... }:
{
  imports = [
    ./entity.nix
  ];

  config = {
    class = "user";
  };

  options = {
    mail = lib.mkEnableOption "internal mail";
    email = lib.mkOption {
      description = "user's email address";
      default = null;
      type = with lib.types; nullOr str;
    };
    inboxes = lib.mkOption {
      type = with lib.types; listOf str;
    };
  };
}
