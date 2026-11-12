{
  app,
  config,
  lib,
  org,
  pkgs,
  ...
}:
let
  port = 8080;
  inherit (app.principal) bindAddress mail;
  inherit (app.keycloak) realms;
  local = "http://[${bindAddress}]:${toString port}";

  # Dependency: an app's kind in org/apps/ derives the client it authenticates as, which names the keycloak.
  clients = lib.concatMap (
    other:
    let
      settings = if other.kind == null then { } else other.${other.kind};
    in
    lib.optional (
      (settings.client or null) != null && settings.client.keycloak == app.name
    ) settings.client
  ) (lib.attrValues org.app);

  secretClients = lib.filter (client: (client.secret or null) != null) clients;

  # Dependency: crates/o11n/src/status.rs logs in as this client to have Keycloak test a realm's mail.
  client = "o11n";

  # Policy: an app matches a user by username, so no one names themselves or renames their account into another's.
  realm = name: settings: {
    realm = name;
    enabled = true;
    inherit (settings) displayName;
    registrationAllowed = false;
    editUsernameAllowed = false;
    resetPasswordAllowed = true;
    bruteForceProtected = true;
    # Dependency: nixos/services/mailserver.nix serves submission as mail.<endpoint>, on 587 with STARTTLS.
    smtpServer = {
      host = "mail.${org.mailserver.endpoint}";
      port = "587";
      starttls = "true";
      ssl = "false";
      auth = "true";
      user = mail.address;
      from = mail.address;
      fromDisplayName = settings.displayName;
    };
  };

  apply = pkgs.writeShellApplication {
    name = "keycloak-realms";
    runtimeInputs = [
      pkgs.curl
      pkgs.jq
    ];
    text = ''
      # Fact: Keycloak takes a request from the app's own address, a ULA, as external, which a realm requires https of,
      # unless a proxy says it came over https, as nginx does.
      curl() {
        command curl -H 'X-Forwarded-Proto: https' "$@"
      }

      auth=$RUNTIME_DIRECTORY/auth
      said=$(
        tr -d '\n' <"$CREDENTIALS_DIRECTORY/admin-client-secret" |
          curl -sS -w '\n%{http_code}' "${local}/realms/master/protocol/openid-connect/token" \
            -d grant_type=client_credentials -d client_id=${client} --data-urlencode client_secret@-
      )
      if [[ ''${said##*$'\n'} != 200 ]]; then
        echo "keycloak-realms: Keycloak refuses ${client}'s login, ''${said##*$'\n'}: ''${said%$'\n'*}" >&2
        echo "keycloak-realms: make ${client} a client of the master realm, with client authentication and service account roles on, its service account an admin, and ${app.handle}'s admin-client-secret its secret" >&2
        exit 1
      fi
      token=$(jq -er .access_token <<<"''${said%$'\n'*}")
      printf 'Authorization: Bearer %s\n' "$token" >"$auth"
      api() {
        curl -sS --fail-with-body -H @"$auth" -H 'Content-Type: application/json' "$@" ||
          { echo "keycloak-realms: ''${*: -1}" >&2 && return 1; }
      }

      jq -c '.[]' <<<"$REALMS" | while IFS= read -r declared; do
        name=$(jq -r .realm <<<"$declared")
        found=$(curl -sS -o /dev/null -w '%{http_code}' -H @"$auth" "${local}/admin/realms/$name")
        case $found in
        200) ;;
        404) jq -c '{realm, enabled}' <<<"$declared" | api -X POST "${local}/admin/realms" --data-binary @- ;;
        *)
          echo "keycloak-realms: Keycloak answers $found for realm $name" >&2
          exit 1
          ;;
        esac
        jq --rawfile password "$CREDENTIALS_DIRECTORY/mail" '.smtpServer.password = ($password | rtrimstr("\n"))' \
          <<<"$declared" | api -X PUT "${local}/admin/realms/$name" --data-binary @-
      done

      # Policy: a declared client is put as declared, over what it was, and what isn't declared of it is left be.
      jq -c '.[]' <<<"$CLIENTS" | while IFS= read -r declared; do
        realm=$(jq -r .realm <<<"$declared")
        client=$(jq -c .representation <<<"$declared")
        if [[ $(jq -r .secret <<<"$declared") == true ]]; then
          client=$(
            jq -c --rawfile secret "$CREDENTIALS_DIRECTORY/client-$(jq -r .clientId <<<"$client")" \
              '.secret = ($secret | rtrimstr("\n"))' <<<"$client"
          )
        fi
        id=$(
          api -G --data-urlencode "clientId=$(jq -r .clientId <<<"$client")" "${local}/admin/realms/$realm/clients" |
            jq -r '.[0].id // empty'
        )
        if [[ -z $id ]]; then
          api -X POST --data-binary @- "${local}/admin/realms/$realm/clients" <<<"$client"
        else
          api -X PUT --data-binary @- "${local}/admin/realms/$realm/clients/$id" <<<"$client"
        fi
      done

      id=$(api "${local}/admin/realms/master/clients?clientId=${client}" | jq -er '.[0].id')

      # Policy: ${client} has the master realm's admin role in its scope alone, rather than every role, as Keycloak's
      # full scope, which it deprecates, gives.
      # Fact: Keycloak takes a client's scope as it stands at each request, so the role goes in before full scope goes.
      api "${local}/admin/realms/master/roles/admin" | jq -c '[.]' |
        api -X POST --data-binary @- "${local}/admin/realms/master/clients/$id/scope-mappings/realm"
      api -X PUT --data-binary '{"fullScopeAllowed": false}' "${local}/admin/realms/master/clients/$id"

      # Policy: Keycloak sends a realm's test mail to the account that asks, here the app's own inbox.
      user=$(api "${local}/admin/realms/master/clients/$id/service-account-user" | jq -er .id)
      jq -n --arg email ${lib.escapeShellArg mail.address} '{email: $email}' |
        api -X PUT "${local}/admin/realms/master/users/$user" --data-binary @-
    '';
  };
in
{
  imports = [
    ../postgresql.nix
  ];

  assertions =
    lib.optional (realms != { }) {
      assertion = org.mailserver != null && mail.send && mail.inbox;
      message = "${app.handle}'s realms send mail, as for a password reset, which Keycloak tests by mailing the app itself: set principal.mail = { inbox = true, send = true } under [app.${app.name}].";
    }
    ++ map (client: {
      assertion = realms ? ${client.realm};
      message = "${client.app}'s client is in the realm ${client.realm}, which ${app.handle} doesn't keep: add keycloak.realms.${client.realm} under [app.${app.name}], or name one it keeps.";
    }) clients;

  o11n.postgresql.databases.${config.services.keycloak.database.name}.user =
    config.services.keycloak.database.username;

  systemd.services.keycloak = {
    after = [ "postgresql.target" ];
    requires = [ "postgresql.target" ];
  };

  # Dependency: the host decrypts the secret of each confidential client, in its app's sops file.
  sops.secrets = {
    "${app.name}/admin-client-secret" = {
      inherit (app.secrets) sopsFile;
    };
  }
  // lib.listToAttrs (
    map (
      client: lib.nameValuePair client.secret.name { inherit (client.secret) sopsFile; }
    ) secretClients
  );

  # Dependency: Keycloak creates the bootstrap client only as it creates the master realm.
  sops.templates."${app.name}-bootstrap.env".content = ''
    KC_BOOTSTRAP_ADMIN_CLIENT_ID=${client}
    KC_BOOTSTRAP_ADMIN_CLIENT_SECRET=${config.sops.placeholder."${app.name}/admin-client-secret"}
  '';

  services.nginx.virtualHosts.${app.endpoint} = {
    forceSSL = app.ssl;
    enableACME = app.ssl;
    extraConfig = ''
      proxy_buffer_size 32k;
      proxy_buffers 4 32k;
      proxy_busy_buffers_size 32k;
    '';
    locations."/" = {
      recommendedProxySettings = true;
      proxyPass = local;
    };
  };

  services.keycloak = {
    enable = true;
    settings = {
      hostname = app.endpoint;
      http-port = port;
      http-host = bindAddress;
      http-enabled = true;
      proxy-headers = "xforwarded";
      # Policy: one keycloak an app, so no cluster to find over the host's networks.
      cache = "local";
    };
    database = {
      host = "/run/postgresql";
      name = app.database;
      username = app.name;
    };
    plugins = [
      pkgs.keycloak.plugins.junixsocket-common
      pkgs.keycloak.plugins.junixsocket-native-common
    ];
  };

  # Policy: Keycloak runs as the app, whose home holds its database's dump.
  systemd.services.keycloak.serviceConfig = {
    User = lib.mkForce app.name;
    Group = lib.mkForce app.name;
    EnvironmentFile = config.sops.templates."${app.name}-bootstrap.env".path;
  };

  systemd.services.keycloak-realms = lib.mkIf (realms != { }) {
    description = "keep ${app.name}'s realms as the org declares them";
    after = [ "keycloak.service" ];
    requires = [ "keycloak.service" ];
    wantedBy = [ "multi-user.target" ];
    environment = {
      REALMS = builtins.toJSON (lib.mapAttrsToList realm realms);
      CLIENTS = builtins.toJSON (
        map (client: {
          inherit (client) realm representation;
          secret = (client.secret or null) != null;
        }) clients
      );
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = lib.getExe apply;
      DynamicUser = true;
      RuntimeDirectory = "keycloak-realms";
      LoadCredential = [
        "admin-client-secret:${config.sops.secrets."${app.name}/admin-client-secret".path}"
        # Dependency: nixos/org/mail.nix declares the password of a principal that sends.
        "mail:${config.sops.secrets."${app.name}/mail".path}"
      ]
      ++ map (
        client: "client-${client.representation.clientId}:${config.sops.secrets.${client.secret.name}.path}"
      ) secretClients;
    };
  };
}
