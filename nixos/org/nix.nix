# nixos/nix.nix
{
  config,
  host,
  inputs,
  o11nInputs,
  lib,
  pkgs,
  org,
  ...
}:

let

  serves = peer: lib.any (service: service.name == "nix-serve") peer.services;

  substituters = lib.filter (
    peer: peer.name != host.name && serves peer && host.reach.${peer.name} != null
  ) (lib.attrValues org.host);
in
{
  # Policy: the one place o11n's tree enters a system, so that a system built with it off tells whether a change to
  # o11n changes what the system is built from.
  options.o11n.source.enable = lib.mkOption {
    description = "whether the host keeps the o11n it's built from at /etc/nix/inputs/o11n";
    type = lib.types.bool;
    default = true;
  };

  config = {
    assertions = map (buildHost: {
      assertion = serves org.host.${buildHost};
      message = "Build host ${buildHost} needs the nix-serve service, or no host can fetch what it builds.";
    }) org.build-hosts;

    nix = {
      package = lib.mkDefault pkgs.lix;
      registry = {
        # Policy: without the checkout's rev and lastModified, which a build host can't know when it
        # evaluates a copy (build-system): a host's system depends on the org's tree alone.
        self.flake = removeAttrs inputs.self [
          "rev"
          "lastModified"
        ];
        o11n.to = {
          type = "path";
          path = "/etc/nix/inputs/o11n";
        };
        nixpkgs.flake = o11nInputs.nixpkgs;
      };
      channel.enable = false;
      settings = {
        download-attempts = 3;
        auto-optimise-store = false;
        bash-prompt-prefix = "(nix:$name)\\040";
        experimental-features = [
          "nix-command"
          "flakes"
        ];
        max-jobs = "auto";
        nix-path = lib.mkForce "nixpkgs=/etc/nix/inputs/nixpkgs";
        substituters = [
          "https://cache.nixos.org"
          "https://cache.lix.systems"
        ]
        # Policy: after cache.nixos.org (40), so that public paths don't come over a vpn.
        ++ map (peer: "http://${host.reach.${peer.name}.fqdn}:5000?priority=50") substituters;
        connect-timeout = 5;
        fallback = true;
        trusted-users = [ "@wheel" ];
        trusted-public-keys = [
          "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
          "cache.lix.systems:aBnZUw8zA7H35Cz2RyKFVs3H4PlGTLawyY5KRbvJR8o="
        ]
        ++ lib.optional (org.service ? nix-serve) (
          builtins.readFile org.service.nix-serve.publicKeys.nix-sign
        );
        use-xdg-base-directories = true;
      };
    };

    environment.etc = {
      "nix/inputs/self".source = "${inputs.self}";
      "nix/inputs/nixpkgs".source = "${o11nInputs.nixpkgs}";
      "nix/inputs/o11n" = lib.mkIf config.o11n.source.enable { source = "${o11nInputs.self}"; };
    };
  };
}
