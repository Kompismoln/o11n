{ name, lib, ... }:
{
  options = {
    name = lib.mkOption {
      description = "domain name";
      type = lib.types.str;
      default = name;
    };
    mailbox = lib.mkEnableOption "mailbox";
  };
}
