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
    ref = lib.types.enum (lib.attrNames (context.spec.${class} or { }));
    module = lib.types.submoduleWith {
      modules = [ ./${class}.nix ];
      specialArgs = {
        inherit context;
      };
    };
  });

  ip = lib.mapAttrs (_: regex: lib.types.strMatching "^${regex}$") ipRegexes;

  kinds = {
    django = ./apps/django.nix;
    drive = ./apps/drive.nix;
    jitsi = ./apps/jitsi.nix;
    keycloak = ./apps/keycloak.nix;
    mobilizon = ./apps/mobilizon.nix;
    photos = ./apps/photos.nix;
    portal = ./apps/portal.nix;
    rolf = ./apps/rolf.nix;
    status = ./apps/status.nix;
    wordpress = { };
  };

  ofKind =
    kind:
    lib.types.submoduleWith {
      modules = [ ./app.nix ] ++ lib.optional (kind != null) kinds.${kind};
      specialArgs = {
        inherit context;
      };
    };

  # Policy: an app's kind is read from the org's spec, as the options its kind gives it can't depend on its config.
  kindOf =
    loc:
    let
      name = lib.last loc;
      kind = context.spec.app.${name}.kind or null;
    in
    if kind == null || kinds ? ${kind} then
      ofKind kind
    else
      throw "app.${name}.kind: ${kind} is no kind of o11n's: set one of ${lib.concatStringsSep ", " (lib.attrNames kinds)}, or none.";

  app =
    let
      base = ofKind null;
    in
    entities.app
    // {
      inherit kinds;
      module = lib.fix (
        self:
        base
        // {
          description = "app and the options of its kind";
          # Fact: the module system substitutes an option's submodules into its type, which would drop these.
          substSubModules = _: self;
          merge = {
            __functor =
              _: loc: defs:
              (kindOf loc).merge loc defs;
            v2 = args: (kindOf args.loc).merge.v2 args;
          };
          # Accommodating for the index, which reads each kind's options as an app's of that kind, `<kind>`.
          getSubOptions =
            prefix:
            let
              own = base.getSubOptions prefix;
            in
            own
            // lib.mapAttrs' (
              kind: _:
              lib.nameValuePair "<${kind}>" (
                removeAttrs ((ofKind kind).getSubOptions (lib.init prefix ++ [ "<${kind}>" ])) (lib.attrNames own)
              )
            ) kinds;
        }
      );
    };
in
entities
// {
  inherit app;
}
// ip
// {
  class = with lib.types; enum (lib.attrNames context.classes);
  flake = lib.types.lazyAttrsOf lib.types.anything;

  domain.module = lib.types.submodule ./domain.nix;
  disk.module = lib.types.submodule ./disk.nix;

  ids.module = lib.types.submoduleWith {
    modules = [ ./ids.nix ];
    specialArgs = {
      inherit context;
    };
  };

  role.ref = lib.types.enum (lib.attrNames (context.spec.role or { }));
  role.module = lib.types.submoduleWith {
    modules = [ ./role.nix ];
    specialArgs = {
      inherit context;
    };
  };

  vpn.ref = lib.types.enum (lib.attrNames (context.spec.vpn or { }));
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

  router.module =
    host:
    lib.types.submoduleWith {
      modules = [ ./router.nix ];
      specialArgs = {
        inherit context host;
      };
    };

  openwrt.module =
    host:
    lib.types.submoduleWith {
      modules = [ ./openwrt.nix ];
      specialArgs = {
        inherit context host;
      };
    };

  network.module =
    host:
    lib.types.submoduleWith {
      modules = [ ./network.nix ];
      specialArgs = {
        inherit context host;
      };
    };

  mailserver.module = lib.types.submoduleWith {
    modules = [ ./mailserver.nix ];
    specialArgs = {
      inherit context;
    };
  };

  # Policy: a file the org names by its path in the org is one, or the org fails to evaluate where it's read.
  orgFile =
    lib.types.coercedTo lib.types.str (file: context.path + "/${file}") (
      lib.types.addCheck lib.types.path builtins.pathExists
    )
    // {
      description = "path of a file in the org";
    };

  allotment.module = lib.types.submoduleWith {
    modules = [ ./allotment.nix ];
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
