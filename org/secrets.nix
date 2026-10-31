{
  context,
  lib,
  entity,
  ...
}:
{
  options = {
    sopsFile = lib.mkOption {
      description = "sops file holding the entity's secrets";
      default = context.path + "/enc/${entity.class}-${entity.name}.yaml";
      type = lib.types.path;
    };
    decryptionKey = lib.mkOption {
      description = "path on the host to the age key that decrypts the entity's secrets";
      default = "/keys/${entity.class}-${entity.name}";
      type = lib.types.str;
    };
  };
}
