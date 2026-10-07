# nixos/org/principals.nix
{
  config,
  lib,
  pkgs,
  host,
  org,
  ...
}:
let
  users = lib.genAttrs host.users (user: org.user.${user});

  apps = lib.filterAttrs (_: app: (lib.elem host.name app.run-on-hosts)) org.app;

  services = lib.genAttrs (builtins.concatMap (role: org.role.${role}.services) host.roles) (
    service: org.service.${service}
  );

  stores = lib.genAttrs (builtins.concatMap (role: org.role.${role}.stores) host.roles) (
    store: org.store.${store}
  );

  entities = builtins.filter (entity: entity.principal != null && entity.id != null) (
    (lib.attrValues users)
    ++ (lib.attrValues apps)
    ++ (lib.attrValues services)
    ++ (lib.attrValues stores)
  );
in
{
  imports = [
    ../preserve.nix
  ];

  sops.secrets = lib.genAttrs' (lib.filter (entity: entity.principal.hasPasswd) entities) (
    entity:
    lib.nameValuePair "${entity.name}/passwd-sha512" {
      neededForUsers = true;
      inherit (entity.secrets) sopsFile;
    }
  );

  users = {
    mutableUsers = false;
    users = lib.genAttrs' entities (
      entity:
      lib.nameValuePair entity.name (
        let
          isNormalUser = entity.class == "user";
          publicKey = entity.publicKeys.ssh-key;
          passwordFile = config.sops.secrets."${entity.name}/passwd-sha512".path;
        in
        rec {
          inherit (entity.principal)
            home
            homeMode
            uid
            ;
          inherit (entity) description;
          inherit isNormalUser;
          isSystemUser = !isNormalUser;
          group = entity.name;
          extraGroups = entity.principal.groups;
          openssh.authorizedKeys.keyFiles = lib.mkIf entity.principal.hasPublicKey [ publicKey ];
          hashedPasswordFile = lib.mkIf entity.principal.hasPasswd passwordFile;
          shell = lib.mkIf entity.principal.hasBash pkgs.bash;
          createHome = home != "/var/empty";
        }
      )
    );

    groups = lib.genAttrs' entities (
      entity:
      lib.nameValuePair entity.name {
        inherit (entity.principal) gid;
        members = [ entity.name ] ++ entity.principal.members;
      }
    );
  };

  o11n.preserve.directories = map (entity: {
    directory = entity.principal.home;
    user = entity.name;
    group = entity.name;
  }) (builtins.filter (entity: entity.principal.home != "/var/empty") entities);

  services.openssh.extraConfig = lib.concatStringsSep "\n" (
    map (entity: ''
      Match User ${entity.name}
        ForceCommand internal-sftp
        AllowTcpForwarding no
        X11Forwarding no
        AllowAgentForwarding no
        PermitTunnel no
    '') (builtins.filter (entity: entity.principal.hasSFTP) entities)
  );
}
