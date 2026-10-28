{
  lib,
  evalNixosModule,
}:
let
  baseConfig = {
    system.stateVersion = lib.trivial.release;
  };

  cfg = evalNixosModule [
    {
      boot.initrd.secrets.test = null;
    }
    baseConfig
  ];

in
{

  test_keycloak_settings_derived = {
    expr = cfg.boot.initrd.secrets.test;
    expected = null;
  };
}
