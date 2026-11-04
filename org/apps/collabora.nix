{ lib, ... }:
{
  options = {
    allowedHosts = lib.mkOption {
      description = "the hosts collabora accepts WOPI from";
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
  };
}
