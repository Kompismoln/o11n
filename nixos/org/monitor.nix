{
  config,
  pkgs,
  ...
}:
let
  blackboxConfig = {
    modules = {
      http_2xx = {
        prober = "http";
        timeout = "5s";
        http = {
          valid_http_versions = [
            "HTTP/1.1"
            "HTTP/2"
            "HTTP/2.0"
          ];
          valid_status_codes = [ ];
          follow_redirects = true;
          preferred_ip_protocol = "ip4";
          tls_config = {
            insecure_skip_verify = false;
          };
        };
      };
      http_post_2xx = {
        prober = "http";
        timeout = "5s";
        http = {
          method = "POST";
          valid_http_versions = [
            "HTTP/1.1"
            "HTTP/2"
          ];
          valid_status_codes = [ ];
          follow_redirects = true;
          preferred_ip_protocol = "ip4";
        };
      };
      tcp_connect = {
        prober = "tcp";
        timeout = "5s";
      };
      icmp = {
        prober = "icmp";
        timeout = "5s";
        icmp = {
          preferred_ip_protocol = "ip4";
        };
      };
    };
  };
in
{
  services.prometheus = {
    enable = true;
    exporters.blackbox = {
      enable = true;
      configFile = pkgs.writeText "blackbox.json" (builtins.toJSON blackboxConfig);
      extraFlags = [
        "--log.level=warn"
      ];
    };
    scrapeConfigs = with config.services.prometheus.exporters; [
      {
        job_name = "mail";
        static_configs = [
          {
            targets = [
              "helsinki.km:${toString postfix.port}"
              "helsinki.km:${toString dovecot.port}"
              "helsinki.km:${toString rspamd.port}"
            ];
            labels = {
              service = "mail";
            };
          }
        ];
      }
      {
        job_name = "nginx";
        static_configs = [
          {
            targets = [
              "helsinki.km:${toString nginx.port}"
              "stationary.km:${toString nginx.port}"
            ];
            labels = {
              service = "nginx";
            };
          }
        ];
      }
      {
        job_name = "php-fpm";
        static_configs = [
          {
            targets = [
              "helsinki.km:${toString php-fpm.port}"
              "stationary.km:${toString php-fpm.port}"
            ];
            labels = {
              service = "php-fpm";
            };
          }
        ];
      }
      {
        job_name = "redis";
        static_configs = [
          {
            targets = [
              "helsinki.km:${toString redis.port}"
              "stationary.km:${toString redis.port}"
            ];
            labels = {
              service = "redis";
            };
          }
        ];
      }
      {
        job_name = "postgres";
        static_configs = [
          {
            targets = [
              "helsinki.km:${toString postgres.port}"
              "stationary.km:${toString postgres.port}"
            ];
            labels = {
              service = "postgres";
            };
          }
        ];
      }
      {
        job_name = "probe_websites";
        metrics_path = "/probe";
        params = {
          module = [ "http_2xx" ];
          target = [ "__param_target__" ];
        };
        static_configs = [
          {
            targets = [
              "https://kompismoln.se"
              "https://klimatkalendern.nu"
              "https://esse.nu"
              "https://chatddx.com"
              "https://sverigesval.org"
            ];
            labels = {
              service = "website";
            };
          }
        ];
        relabel_configs = [
          {
            source_labels = [ "__address__" ];
            target_label = "__param_target";
          }
          {
            source_labels = [ "__param_target" ];
            target_label = "instance";
          }
          {
            source_labels = [ "__param_target" ];
            regex = "https?://([^/:]+).*";
            target_label = "domain";
          }
          {
            target_label = "__address__";
            replacement = "stationary.km:9115";
          }
        ];
        scrape_interval = "60s";
        scrape_timeout = "30s";
      }
    ];
  };
  services.nginx.virtualHosts."stationary.km".locations."/grafana/" = {
    proxyPass = "http://localhost:9999";
    proxyWebsockets = true;
  };

  users.groups.grafana.gid = config.ids.uids.grafana;

  services.grafana = {
    enable = true;
    settings = {
      server = {
        http_port = 9999;
        domain = "stationary.km";
        root_url = "http://stationary.km/grafana/";
        serve_from_sub_path = true;
      };
    };
    provision.datasources = {
      settings.datasources = [
        {
          name = "Prometheus localhost";
          url = "http://localhost:9090";
          type = "prometheus";
          isDefault = true;
        }
      ];
    };
  };

  services.loki = {
    enable = true;
    configuration = {
      auth_enabled = false;
      pattern_ingester = {
        enabled = true;
      };

      server = {
        http_listen_port = 0;
        grpc_listen_port = 0;
      };

      common = {
        ring = {
          instance_addr = "127.0.0.1";
          kvstore = {
            store = "memberlist";
          };
        };
        replication_factor = 1;
        path_prefix = "/var/lib/loki/working";
      };

      schema_config = {
        configs = [
          {
            from = "2022-01-22";
            store = "tsdb";
            object_store = "filesystem";
            schema = "v13";
            index = {
              prefix = "index_";
              period = "24h";
            };
          }
        ];
      };
      storage_config = {
        filesystem = {
          directory = "/var/lib/loki/chunks";
        };
        tsdb_shipper = {
          active_index_directory = "/var/lib/loki/tsdb-index";
          cache_location = "/var/lib/loki/tsdb-cache";
          cache_ttl = "24h";
        };
      };

      limits_config = {
        retention_period = "30d";
      };
      memberlist = {
        bind_addr = [ "0.0.0.0" ];
        bind_port = 7946;
      };
    };
  };

}
