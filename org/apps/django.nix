{ app, lib, ... }:
{
  options = {
    input = lib.mkOption {
      description = "the org's input whose packages.<system> has the app's django-app and scripts";
      type = lib.types.str;
      default = app.name;
      defaultText = lib.literalExpression "name";
    };
    module = lib.mkOption {
      description = "the app's django module";
      type = lib.types.str;
    };
    locationProxy = lib.mkOption {
      description = "the nginx location that django serves, the rest being static";
      type = lib.types.str;
      default = "/";
    };
    trustedOrigins = lib.mkOption {
      description = "django's CSRF_TRUSTED_ORIGINS";
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
    timeout = lib.mkOption {
      description = "gunicorn's timeout, in seconds";
      type = lib.types.int;
      default = 30;
    };
  };
}
