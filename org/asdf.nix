{
  config = {
    class = "org";
    inventory = lib.mkMerge (
      lib.concatMap (host: [
        { host = [ host.name ]; }
        host.inventory
      ]) (lib.attrValues config.host)
    );
  };
  config = {
    context.org = lib.mapAttrs (
      class: entities:
      lib.genAttrs entities (entity: {
        grants = {
          ${config.class} = config.name;
        };
      })
    ) config.inventory;
  };
}
