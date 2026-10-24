{
  config,
  host,
  lib,
  org,
  ...
}:

let
  inherit (lib)
    mkEnableOption
    mkIf
    optionalString
    ;

  cfg = config.o11n.nginx;
  vpn = org.vpn.wg0;
  hostname = host.network.wg0.fqdn;
in
{
  options.o11n.nginx = {
    enable = mkEnableOption "nginx web server.";
    monitor = mkEnableOption "nginx web server.";
  };

  config = mkIf cfg.enable {
    networking.firewall.allowedTCPPorts = [
      80
      443
    ];

    security.acme = {
      acceptTerms = true;
      defaults.email = org.contact;
    };

    services.nginx = {
      enable = true;
      recommendedBrotliSettings = true;
      recommendedOptimisation = true;
      recommendedProxySettings = true;
      recommendedTlsSettings = true;

      commonHttpConfig = ''
        log_format main escape=json '{'
          '"time_iso8601": "$time_iso8601", '
          '"status": "$status", '
          '"remote_addr": "$remote_addr", '
          '"remote_user": "$remote_user", '
          '"request_method": "$request_method", '
          '"request_uri": "$request_uri", '
          '"server_protocol": "$server_protocol", '
          '"host": "$host", '
          '"scheme": "$scheme", '
          '"request_length": "$request_length", '
          '"body_bytes_sent": $body_bytes_sent, '
          '"http_referer": "$http_referer", '
          '"http_user_agent": "$http_user_agent", '
          '"http_x_forwarded_for": "$http_x_forwarded_for", '
          '"request_time": "$request_time", '
          '"upstream_addr": "$upstream_addr", '
          '"upstream_status": "$upstream_status", '
          '"upstream_response_time": "$upstream_response_time", '
          '"upstream_connect_time": "$upstream_connect_time" '
        '}';

        access_log /var/log/nginx/access.log main;
      '';

      appendConfig = ''
        worker_processes auto;
        worker_cpu_affinity auto;
      '';
    };

    services.logrotate.settings.nginx = {
      frequency = "weekly";
      rotate = 0;
    };

    # Request and response bodies too large for memory are buffered here.
    o11n.preserve.directories = [
      {
        directory = "/var/cache/nginx";
        inherit (config.services.nginx) user group;
        mode = "0750";
      }
    ];

    services.prometheus.exporters.nginx = {
      enable = true;
      scrapeUri = "http://${hostname}/nginx_status";
    };
    services.nginx.virtualHosts = {
      "_" = {
        default = true;
        rejectSSL = true;
        locations."/" = {
          return = "444";
        };
      };
      "${hostname}".locations."/nginx_status" = {
        extraConfig = ''
          stub_status on;
          access_log off;
          allow 127.0.0.1;
          allow ${vpn.address};
          ${optionalString config.networking.enableIPv6 "allow ::1;"}
          deny all;
        '';
      };
    };

    #services.alloy = {
    #  enable = true;
    #  extraFlags = [
    #    "--server.http.listen-addr=0.0.0.0:${toString ids.alloy.port}"
    #  ];
    #};
    #users.users.alloy = {
    #  uid = ids.alloy.uid;
    #  isSystemUser = true;
    #  group = "alloy";
    #  extraGroups = [ "nginx" ];
    #};
    #users.groups.alloy = {
    #  gid = config.users.users.alloy.uid;
    #};

    environment.etc."alloy/config.alloy".text = ''
      local.file_match "nginx_json_access_log" {
          path_targets = [
              {
              "__path__" = "/var/log/nginx/access.log",
              "job" = "nginx",
              "log_instance" = "${hostname}",
              "log_type" = "access_json",
              },
          ]
      }

      local.file_match "nginx_plain_error_log" {
          path_targets = [
              {
              "__path__" = "/var/log/nginx/error.log",
              "job" = "nginx",
              "log_instance" = "${hostname}",
              "log_type" = "error_plain",
              },
          ]
      }

      loki.source.file "nginx_access_source" {
          targets    = local.file_match.nginx_json_access_log.targets
          forward_to = [loki.process.nginx_json_parser.receiver]
      }

      loki.source.file "nginx_error_source" {
          targets    = local.file_match.nginx_plain_error_log.targets
          forward_to = [loki.write.default.receiver]
      }

      loki.process "nginx_json_parser" {
          stage.json {
              expressions = {
                  "host" = "",
                  "status" = "",
              }
          }

          stage.labels {
              values = {
                  host   = "",
                  status = "",
              }
          }

          stage.timestamp {
              source = "time_iso8601"
              format = "RFC3339"
          }

          forward_to = [loki.write.default.receiver]
      }

      loki.write "default" {
          endpoint {
              url = "http://${""}:3100/loki/api/v1/push"
          }
      }
    '';
  };
}
