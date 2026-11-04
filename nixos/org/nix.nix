# nixos/nix.nix
{
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
  assertions = map (buildHost: {
    assertion = serves org.host.${buildHost};
    message = "Build host ${buildHost} needs the nix-serve service, or no host can fetch what it builds.";
  }) org.build-hosts;

  nix = {
    package = lib.mkDefault pkgs.lix;
    registry = {
      # Without the checkout's rev and lastModified, which a build host can't know when it
      # evaluates a copy (build-system): a host's system depends on the org's tree alone.
      self.flake = removeAttrs inputs.self [
        "rev"
        "lastModified"
      ];
      o11n = {
        from = {
          id = "o11n";
          type = "indirect";
        };
        to = org.flake;
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
      # After cache.nixos.org (40), so that public paths don't come over a vpn.
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
  };
}
