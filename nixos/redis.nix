{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.o11n.redis;

  mkValueString =
    value:
    if value == true then
      "yes"
    else if value == false then
      "no"
    else
      lib.generators.mkValueStringDefault { } value;

  redisConfig =
    settings:
    pkgs.writeText "redis.conf" (
      lib.generators.toKeyValue {
        listsAsDuplicateKeys = true;
        mkKeyValue = lib.generators.mkKeyValueDefault { inherit mkValueString; } " ";
      } settings
    );

  redisName = name: "${name}-redis";
  enabledServers = lib.filterAttrs (_: conf: conf.enable) cfg.servers;

in
{
  ###### interface

  options = {

    o11n.redis = {
      package = lib.mkPackageOption pkgs "redis" { };

      vmOverCommit =
        lib.mkEnableOption ''
          set `vm.overcommit_memory` sysctl to 1
          (Suggested for Background Saving: <https://redis.io/docs/get-started/faq/>)
        ''
        // {
          default = true;
        };

      servers = lib.mkOption {
        type =
          with lib.types;
          attrsOf (
            submodule (
              { config, name, ... }:
              {
                options = {
                  enable = lib.mkEnableOption "Redis server";

                  user = lib.mkOption {
                    type = types.str;
                  };

                  group = lib.mkOption {
                    type = types.str;
                    default = config.user;
                  };

                  home = lib.mkOption {
                    type = types.str;
                  };

                  port = lib.mkOption {
                    type = types.port;
                    default = 6379;
                  };

                  extraParams = lib.mkOption {
                    type = with types; listOf str;
                    default = [ ];
                    description = "Extra parameters to append to redis-server invocation";
                    example = [ "--sentinel" ];
                  };

                  bind = lib.mkOption {
                    type = with types; nullOr str;
                    default = "127.0.0.1";
                    description = ''
                      The IP interface to bind to.
                      `null` means "all interfaces".
                    '';
                    example = "192.0.2.1";
                  };

                  unixSocket = lib.mkOption {
                    type = with types; nullOr path;
                    default = "/run/${redisName name}/redis.sock";
                    defaultText = lib.literalExpression ''
                      if name == "" then "/run/redis/redis.sock" else "/run/redis-''${name}/redis.sock"
                    '';
                    description = "The path to the socket to bind to.";
                  };

                  unixSocketPerm = lib.mkOption {
                    type = types.int;
                    default = 660;
                    description = "Change permissions for the socket";
                    example = 600;
                  };

                  logLevel = lib.mkOption {
                    type = types.str;
                    default = "notice"; # debug, verbose, notice, warning
                    example = "debug";
                    description = "Specify the server verbosity level, options: debug, verbose, notice, warning.";
                  };

                  logfile = lib.mkOption {
                    type = types.str;
                    default = "/dev/null";
                    description = "Specify the log file name. Also 'stdout' can be used to force Redis to log on the standard output.";
                    example = "/var/log/redis.log";
                  };

                  syslog = lib.mkOption {
                    type = types.bool;
                    default = true;
                    description = "Enable logging to the system logger.";
                  };

                  databases = lib.mkOption {
                    type = types.int;
                    default = 16;
                    description = "Set the number of databases.";
                  };

                  maxclients = lib.mkOption {
                    type = types.int;
                    default = 10000;
                    description = "Set the max number of connected clients at the same time.";
                  };

                  save = lib.mkOption {
                    type = with types; listOf (listOf int);
                    default = [
                      [
                        900
                        1
                      ]
                      [
                        300
                        10
                      ]
                      [
                        60
                        10000
                      ]
                    ];
                    description = ''
                      The schedule in which data is persisted to disk, represented as a list of lists where the first element represent the amount of seconds and the second the number of changes.

                      If set to the empty list (`[]`) then RDB persistence will be disabled (useful if you are using AOF or don't want any persistence).
                    '';
                  };

                  slaveOf = lib.mkOption {
                    type =
                      with types;
                      nullOr (
                        submodule (_: {
                          options = {
                            ip = lib.mkOption {
                              type = str;
                              description = "IP of the Redis master";
                              example = "192.168.1.100";
                            };

                            port = lib.mkOption {
                              type = port;
                              description = "port of the Redis master";
                              default = 6379;
                            };
                          };
                        })
                      );

                    default = null;
                    description = "IP and port to which this redis instance acts as a slave.";
                    example = {
                      ip = "192.168.1.100";
                      port = 6379;
                    };
                  };

                  masterAuth = lib.mkOption {
                    type = with types; nullOr str;
                    default = null;
                    description = ''
                      If the master is password protected (using the requirePass configuration)
                      it is possible to tell the slave to authenticate before starting the replication synchronization
                      process, otherwise the master will refuse the slave request.
                      (STORED PLAIN TEXT, WORLD-READABLE IN NIX STORE)
                    '';
                  };

                  masterAuthFile = lib.mkOption {
                    type = with types; nullOr path;
                    default = null;
                    description = "File with password for the master user.";
                    example = "/run/keys/redis-master-password";
                  };

                  masterUser = lib.mkOption {
                    type = with types; nullOr str;
                    default = null;
                    description = ''
                      If the master is password protected via ACLs this option can be used to specify
                      the Redis user that is used by replicas.'';
                  };

                  requirePass = lib.mkOption {
                    type = with types; nullOr str;
                    default = null;
                    description = ''
                      Password for database (STORED PLAIN TEXT, WORLD-READABLE IN NIX STORE).
                      Use requirePassFile to store it outside of the nix store in a dedicated file.
                    '';
                    example = "letmein!";
                  };

                  requirePassFile = lib.mkOption {
                    type = with types; nullOr path;
                    default = null;
                    description = "File with password for the database.";
                    example = "/run/keys/redis-password";
                  };

                  sentinelAuthPassFile = lib.mkOption {
                    type = with types; nullOr path;
                    default = null;
                    description = "File with password for connecting to other Sentinel instances.";
                    example = "/run/keys/sentinel-password";
                  };

                  sentinelAuthUser = lib.mkOption {
                    type = with types; nullOr str;
                    default = null;
                    description = "The username to use to monitor a master from Sentinel.";
                  };

                  sentinelMasterHost = lib.mkOption {
                    type = with types; nullOr str;
                    default = null;
                    description = "The IP address (recommended) or hostname of the Redis master that Sentinel will monitor.";
                  };

                  sentinelMasterName = lib.mkOption {
                    type = with types; nullOr str;
                    default = null;
                    description = "The master name of the Redis master that Sentinel will monitor.";
                  };

                  sentinelMasterPort = lib.mkOption {
                    type = with types; nullOr int;
                    default = null;
                    description = "The TCP port of the Redis master that Sentinel will monitor.";
                  };

                  sentinelMasterQuorum = lib.mkOption {
                    type = with types; nullOr int;
                    default = null;
                    description = "The Sentinel quorum (minimum number of Sentinel nodes online for failover)";
                  };

                  appendOnly = lib.mkOption {
                    type = types.bool;
                    default = false;
                    description = "By default data is only periodically persisted to disk, enable this option to use an append-only file for improved persistence.";
                  };

                  appendFsync = lib.mkOption {
                    type = types.str;
                    default = "everysec"; # no, always, everysec
                    description = "How often to fsync the append-only log, options: no, always, everysec.";
                  };

                  slowLogLogSlowerThan = lib.mkOption {
                    type = types.int;
                    default = 10000;
                    description = "Log queries whose execution take longer than X in milliseconds.";
                    example = 1000;
                  };

                  slowLogMaxLen = lib.mkOption {
                    type = types.int;
                    default = 128;
                    description = "Maximum number of items to keep in slow log.";
                  };

                  settings = lib.mkOption {
                    # TODO: this should be converted to freeformType
                    type =
                      with types;
                      attrsOf (oneOf [
                        bool
                        int
                        str
                        (listOf str)
                      ]);
                    default = { };
                    description = ''
                      Redis configuration. Refer to
                      <https://redis.io/topics/config>
                      for details on supported values.
                    '';
                    example = lib.literalExpression ''
                      {
                        loadmodule = [ "/path/to/my_module.so" "/path/to/other_module.so" ];
                      }
                    '';
                  };
                };
                config.settings = lib.mkMerge [
                  {
                    inherit (config)
                      port
                      logfile
                      databases
                      maxclients
                      appendOnly
                      ;
                    daemonize = false;
                    supervised = "systemd";
                    loglevel = config.logLevel;
                    syslog-enabled = config.syslog;
                    save =
                      if config.save == [ ] then
                        ''""'' # Disable saving with `save = ""`
                      else
                        map (d: "${toString (builtins.elemAt d 0)} ${toString (builtins.elemAt d 1)}") config.save;
                    dbfilename = "dump.rdb";
                    dir = config.home;
                    appendfsync = config.appendFsync;
                    slowlog-log-slower-than = config.slowLogLogSlowerThan;
                    slowlog-max-len = config.slowLogMaxLen;
                  }
                  (lib.mkIf (config.bind != null) { inherit (config) bind; })
                  (lib.mkIf (config.unixSocket != null) {
                    unixsocket = config.unixSocket;
                    unixsocketperm = toString config.unixSocketPerm;
                  })
                  (lib.mkIf (config.slaveOf != null) {
                    slaveof = "${config.slaveOf.ip} ${toString config.slaveOf.port}";
                  })
                  (lib.mkIf (config.masterAuth != null) { masterauth = config.masterAuth; })
                  (lib.mkIf (config.requirePass != null) { requirepass = config.requirePass; })
                ];
              }
            )
          );
        description = "Configuration of multiple `redis-server` instances.";
        default = { };
      };
    };

  };

  ###### implementation

  config = lib.mkIf (enabledServers != { }) {

    assertions = lib.concatLists (
      lib.mapAttrsToList (name: conf: [
        {
          assertion = conf.requirePass != null -> conf.requirePassFile == null;
          message = ''
            You can only set one of .redis.servers.${name}.requirePass
            or .redis.servers.${name}.requirePassFile
          '';
        }
        {
          assertion = conf.masterAuth != null -> conf.masterAuthFile == null;
          message = ''
            You can only set one of .redis.servers.${name}.masterAuth
            or .redis.servers.${name}.masterAuthFile
          '';
        }
        {
          assertion = conf.masterUser != null -> (conf.masterAuth != null || conf.masterAuthFile != null);
          message = ''
            If using .redis.servers.${name}.masterUser, either
            .redis.servers.${name}.masterAuthFile or
            .redis.servers.${name}.masterAuth must be provided
          '';
        }
        {
          assertion =
            conf.sentinelMasterName != null
            -> (
              conf.sentinelMasterHost != null
              && conf.sentinelMasterPort != null
              && conf.sentinelMasterQuorum != null
            );
          message = ''
            For Sentinel,
            .redis.servers.${name}.sentinelMasterName,
            .redis.servers.${name}.sentinelMasterHost,
            .redis.servers.${name}.sentinelMasterPort,
            and .redis.servers.${name}.sentinelMasterQuorum
            must all be provided
          '';
        }
        {
          assertion = conf.sentinelAuthPassFile != null -> conf.sentinelMasterName != null;
          message = ''
            For Sentinel authentication, .redis.servers.${name}.sentinelMasterName,
            must be provided
          '';
        }
      ]) enabledServers
    );

    boot.kernel.sysctl = lib.mkIf cfg.vmOverCommit {
      "vm.overcommit_memory" = lib.mkDefault "1";
    };

    environment.systemPackages = [ cfg.package ];

    systemd.services = lib.mapAttrs' (
      name: conf:
      lib.nameValuePair (redisName name) {
        description = "Redis Server - ${redisName name}";

        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];

        serviceConfig = {
          ExecStart = "${cfg.package}/bin/${
            cfg.package.serverBin or "redis-server"
          } ${conf.home}/redis.conf ${lib.escapeShellArgs conf.extraParams}";

          # NOTE: Redis/Valkey Sentinel persists dynamic cluster state by rewriting its
          # configuration file at runtime (redis.conf). This includes monitors,
          # authentication credentials, and failover metadata, and this behaviour
          # cannot be disabled.
          # As a result, a fully declarative configuration is not possible for
          # Sentinel-managed options. The preStart logic below appends sentinel
          # configuration only if it is not already present, in order to avoid
          # overwriting state that is owned and maintained by Sentinel itself.
          # This is an intentional deviation from strict declarative semantics and
          # is required for correct Sentinel operation.
          ExecStartPre =
            "+"
            + pkgs.writeShellScript "${redisName name}-prep-conf" (
              let
                redisConfVar = "${conf.home}/redis.conf";
                redisConfRun = "/run/${redisName name}/nixos.conf";
                redisConfStore = redisConfig conf.settings;
              in
              ''
                touch "${redisConfVar}" "${redisConfRun}"
                chown '${conf.user}':'${conf.group}' "${redisConfVar}" "${redisConfRun}"
                chmod 0600 "${redisConfVar}" "${redisConfRun}"
                if [ ! -s ${redisConfVar} ]; then
                  echo 'include "${redisConfRun}"' > "${redisConfVar}"
                fi
                echo 'include "${redisConfStore}"' > "${redisConfRun}"
                ${lib.optionalString (conf.requirePassFile != null) ''
                  echo "requirepass $(cat ${lib.escapeShellArg conf.requirePassFile})" >> "${redisConfRun}"
                ''}
                ${lib.optionalString (conf.masterUser != null) ''
                  echo "masteruser ${conf.masterUser}" >> "${redisConfRun}"
                ''}
                ${lib.optionalString (conf.masterAuthFile != null) ''
                  echo "masterauth $(cat ${lib.escapeShellArg conf.masterAuthFile})" >> "${redisConfRun}"
                ''}
                ${lib.optionalString (conf.sentinelMasterHost != null) ''
                  sentinel_monitor_line="sentinel monitor ${conf.sentinelMasterName} ${conf.sentinelMasterHost} ${toString conf.sentinelMasterPort} ${toString conf.sentinelMasterQuorum}"
                  if grep -qE "^sentinel monitor ${conf.sentinelMasterName}\b" "${redisConfVar}"; then
                    sed -i \
                      "s|^sentinel monitor ${conf.sentinelMasterName}\b.*|$sentinel_monitor_line|" "${redisConfVar}"
                  else
                    echo "$sentinel_monitor_line" >> "${redisConfVar}"
                  fi
                ''}
                ${lib.optionalString (conf.sentinelAuthUser != null) ''
                  sentinel_auth_user_line="sentinel auth-user ${conf.sentinelMasterName} ${conf.sentinelAuthUser}"
                  if grep -qE "^sentinel auth-user ${conf.sentinelMasterName}\b" "${redisConfVar}"; then
                    sed -i \
                      "s|^sentinel auth-user ${conf.sentinelMasterName}\b.*|$sentinel_auth_user_line|" "${redisConfVar}"
                  else
                    echo "$sentinel_auth_user_line" >> "${redisConfVar}"
                  fi
                ''}
                ${lib.optionalString (conf.sentinelAuthPassFile != null) ''
                  sentinel_auth_pass_line="sentinel auth-pass ${conf.sentinelMasterName} $(cat ${lib.escapeShellArg conf.sentinelAuthPassFile})"
                  if grep -qE "^sentinel auth-pass ${conf.sentinelMasterName}\b" "${redisConfVar}"; then
                    sed -i \
                      "s|^sentinel auth-pass ${conf.sentinelMasterName}\b.*|$sentinel_auth_pass_line|" "${redisConfVar}"
                  else
                    echo "$sentinel_auth_pass_line" >> "${redisConfVar}"
                  fi
                ''}
              ''
            );
          Type = "notify";
          # User and group
          User = conf.user;
          Group = conf.group;
          # Runtime directory and mode
          RuntimeDirectory = redisName name;
          RuntimeDirectoryMode = "0750";
          # State directory and mode
          StateDirectory = "${name}/redis";
          StateDirectoryMode = "0700";
          # Access write directories
          UMask = "0077";
          # Capabilities
          CapabilityBoundingSet = "";
          # Security
          NoNewPrivileges = true;
          # Process Properties
          LimitNOFILE = lib.mkDefault "${toString (conf.maxclients + 32)}";
          # Sandboxing
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          PrivateDevices = true;
          PrivateUsers = true;
          ProtectClock = true;
          ProtectHostname = true;
          ProtectKernelLogs = true;
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
          ProtectControlGroups = true;
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
            "AF_UNIX"
          ];
          RestrictNamespaces = true;
          LockPersonality = true;
          MemoryDenyWriteExecute = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          PrivateMounts = true;
          # System Call Filtering
          SystemCallArchitectures = "native";
          SystemCallFilter = "~@cpu-emulation @debug @keyring @memlock @mount @obsolete @privileged @resources @setuid";
        };
      }
    ) enabledServers;

  };
}
