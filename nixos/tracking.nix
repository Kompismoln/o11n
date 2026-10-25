{
  config,
  lib,
  ...
}:

let
  inherit (lib) mkEnableOption mkIf types;
  cfg = config.o11n.tracking;

  nginxJsonLogFormatContent = ''
    {
      "timestamp": "$time_iso8601",
      "remote_addr": "$remote_addr", 
      "http_x_forwarded_for": "$http_x_forwarded_for",
      "request_method": "$request_method",
      "request_uri": "$request_uri",
      "server_protocol": "$server_protocol",
      "status": "$status",
      "body_bytes_sent": "$body_bytes_sent",
      "http_referer": "$http_referer",
      "http_user_agent": "$http_user_agent",
      "request_time": "$request_time",
      "host": "$host",
      "upstream_addr": "$upstream_addr",
      "upstream_status": "$upstream_status",
      "upstream_response_time": "$upstream_response_time"
    }
  '';

in
{
  options.o11n.tracking = {
    enable = mkEnableOption "website visitor tracking";

    nginxJsonLogFormatName = lib.mkOption {
      type = types.str;
      default = "json_tracking";
      description = "The name of the Nginx log format for JSON tracking.";
    };

    nginxAccessLogPath = lib.mkOption {
      type = types.str;
      default = "/var/log/nginx/access_tracking.json.log";
      description = "Path for the JSON access log for tracked virtual hosts.";
    };
  };

  config = mkIf cfg.enable {
    services.nginx.logFormats = {
      "${cfg.nginxJsonLogFormatName}" = nginxJsonLogFormatContent;
    };

    services.loki = {
      enable = true;
    };

    services.promtail = {
      enable = true;
      configuration = {
        server = {
          http_listen_port = 9080;
          grpc_listen_port = 0;
        };
        positions = {
          filename = "/var/lib/promtail/positions.yaml";
        };
        clients = [
          {
            url = "http://localhost:${toString config.services.loki.configuration.server.http_listen_port}/loki/api/v1/push";
          }
        ];
        scrape_configs = [
          {
            job_name = "nginx-json-tracking";
            static_configs = [
              {
                targets = [ "localhost" ];
                labels = {
                  __path__ = cfg.nginxAccessLogPath;
                  job = "nginx_access_logs";
                  host = config.networking.hostName;
                };
              }
            ];
          }
        ];
      };
    };

    services.grafana.provision.datasources.settings.datasources = lib.mkMerge [
      (config.services.grafana.provision.datasources.settings.datasources or [ ])
      [
        {
          name = "Loki (Tracking)";
          type = "loki";
          url = "http://localhost:${toString config.services.loki.configuration.server.http_listen_port}";
          access = "proxy";
          isDefault = false;
        }
      ]
    ];
  };
}
