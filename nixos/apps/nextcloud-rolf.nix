# nixos/apps/nextcloud-rolf.nix
{
  app,
  host,
  inputs,
  org,
  pkgs,
  ...
}:
let
  nextcloud = org.app.${app.nextcloud-rolf.nextcloud};
  packages = inputs.${app.nextcloud-rolf.input}.packages.${host.system};
  user = nextcloud.name;
  home = "${nextcloud.principal.home}/nextcloud/data/rolf/files/+pub";
  siteRoot = "${home}/_site";
  sourceRoot = "${home}/_src";

  sync =
    pkgs.runCommand app.name
      {
        src = packages.default;
        nativeBuildInputs = [ pkgs.makeWrapper ];
      }
      ''
        mkdir -p $out/bin

        makeWrapper \
          $src/bin/rolf \
          $out/bin/${app.name} \
            --append-flags ${home} \
            --append-flags ${sourceRoot} \
            --append-flags ${siteRoot} \
            --append-flags --watch
      '';
in
{
  environment.systemPackages = [ sync ];

  services.nginx.virtualHosts.${app.endpoint} = {
    forceSSL = app.ssl;
    enableACME = app.ssl;

    root = siteRoot;
    locations."/" = {
      index = "index.html";
      tryFiles = "$uri $uri/ /404.html";
    };
  };

  systemd.timers."${app.name}-build" = {
    description = "Scheduled building of todays articles";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "01:00";
      Unit = "${app.name}-build.service";
    };
  };

  systemd.services = {
    "${app.name}-build" = {
      description = "run ${app.name}-build";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${packages.gems}/bin/jekyll build -s ${sourceRoot} -d ${siteRoot} --disable-disk-cache";
        WorkingDirectory = sourceRoot;
        User = user;
        Group = user;
      };
    };
    ${app.name} = {
      description = "run ${app.name}";
      serviceConfig = {
        ExecStart = "${sync}/bin/${app.name}";
        WorkingDirectory = home;
        User = user;
        Group = user;
      };
      wantedBy = [ "multi-user.target" ];
    };
  };
}
