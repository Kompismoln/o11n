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
    identityFile = lib.mkOption {
      description = "the entity's age key, encrypted to itself, its actors and the root identities";
      default = context.path + "/enc/${entity.class}-${entity.name}.age";
      type = lib.types.path;
    };
    decryptionKey = lib.mkOption {
      description = "path on the host to the age key that decrypts the entity's secrets";
      default = "/keys/${entity.class}-${entity.name}";
      type = lib.types.str;
    };
  };
}
