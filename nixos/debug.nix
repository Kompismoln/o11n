{
  config,
  lib,
  options,
  ...
}:
let
  inherit (lib)
    mkOption
    types
    ;

  #debug = options.preservation.preserveAt.type.nestedTypes;
  cfg = config.o11n.debug;
  debug = options.nix.settings.type.nestedTypes.freeformType.getSubModules;
in
{
  options.o11n.debug = {
    enable = mkOption {
      description = "Enable this debugging module";
      type = types.bool;
      default = false;
    };
  };
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = true;
        message = "Debug: ${debug}";
      }
      {
        assertion = false;
        message = "Debug: subOptions has keys: ${builtins.concatStringsSep ", " (builtins.attrNames debug)}";
      }
    ];
  };

}
