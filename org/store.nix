{ config, lib, ... }:
{
  imports = [ ./entity.nix ];

  options.smb = lib.mkOption {
    description = "the SMB share the store is, which it logs in to with its smb-password, or null";
    type = lib.types.nullOr (
      lib.types.submodule {
        options = {
          host = lib.mkOption {
            description = "the SMB server";
            type = lib.types.str;
          };
          share = lib.mkOption {
            description = "the share on the server";
            type = lib.types.str;
          };
          login = lib.mkOption {
            description = "the user it logs in as";
            type = lib.types.str;
          };
        };
      }
    );
    default = null;
  };

  config = {
    class = "store";
    keys = lib.optionalAttrs (config.smb != null) { smb-password = "passphrase"; };
  };
}
