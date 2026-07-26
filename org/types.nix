lib: context:
let
  ipRegexes = rec {
    octet = "[0-9]{1,3}";

    hextet = "[0-9a-f]{1,4}";
    hextetP4 = "[0-9a-f]{4}";
    hextetP8 = "[0-9a-f]{8}";
    hextetP32 = "[0-9a-f]{32}";

    hexpair = "[0-9a-f]{2}";

    mac = "${hexpair}(:${hexpair}){5}";

    globalPrefix6 = "${hextet}:${hextet}:${hextet}";
    globalPrefix4 = "${octet}.${octet}";

    prefixLength6 = "(64|128)";
    prefixLength4 = "(24|32)";

    subnetPrefix6 = "${globalPrefix6}:${hextet}";
    subnetPrefix4 = "${globalPrefix4}.${octet}";

    subnetCidr6 = "${subnetPrefix6}::/${prefixLength6}";
    subnetCidr4 = "${subnetPrefix4}.0/${prefixLength4}";

    host6 = "${subnetPrefix6}:(:${hextet}){1,3}";
    host4 = "${subnetPrefix4}.${octet}";

    hostCidr6 = "${host6}/${prefixLength6}";
    hostCidr4 = "${host4}/${prefixLength4}";

    subnetCidrBracketed6 = "[[]${subnetPrefix6}::[]]/${prefixLength6}";
    hostCidrBracketed6 = "[[]${host6}[]]/${prefixLength6}";
  };

  entities = lib.genAttrs (lib.attrNames context.classes) (class: {
    ref = lib.types.enum (lib.attrNames context.spec.${class});
    module = lib.types.submoduleWith {
      modules = [ ./${class}.nix ];
      specialArgs = {
        inherit context;
      };
    };
  });

  ip = lib.mapAttrs (_: regex: lib.types.strMatching "^${regex}$") ipRegexes;
in
entities
// ip
// {
  class = with lib.types; enum (lib.attrNames context.classes);

  domain.module = lib.types.submodule ./domain.nix;
  disk.module = lib.types.submodule ./disk.nix;

  ids.module = lib.types.submoduleWith {
    modules = [ ./ids.nix ];
    specialArgs = {
      inherit context;
    };
  };

  role.ref = lib.types.enum (lib.attrNames context.spec.role);
  role.module = lib.types.submoduleWith {
    modules = [ ./role.nix ];
    specialArgs = {
      inherit context;
    };
  };

  vpn.ref = lib.types.enum (lib.attrNames context.spec.vpn);
  vpn.module = lib.types.submoduleWith {
    modules = [ ./vpn.nix ];
    specialArgs = {
      inherit context;
    };
  };

  home.module =
    host:
    lib.types.submoduleWith {
      modules = [ ./home.nix ];
      specialArgs = {
        inherit context host;
      };
    };

  network.module = lib.types.submoduleWith {
    modules = [ ./network.nix ];
    specialArgs = {
      inherit context;
    };
  };

  mailserver.module = lib.types.submoduleWith {
    modules = [ ./mailserver.nix ];
    specialArgs = {
      inherit context;
    };
  };

  theme.module = lib.types.submoduleWith {
    modules = [ ./theme.nix ];
    specialArgs = {
      inherit context;
    };
  };
}
