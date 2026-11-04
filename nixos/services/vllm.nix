# nixos/services/vllm.nix
{
  host,
  inputs,
  lib,
  org,
  ...
}:
let
  settings = org.service.vllm.hosts.${host.name} or { };
in
{
  imports = [
    ../vllm.nix
  ];

  o11n.vllm = lib.optionalAttrs (settings != { }) {
    inherit (settings) report;
    servers = lib.mapAttrs (
      _: server:
      removeAttrs server [ "nixpkgs" ]
      // lib.optionalAttrs (server.nixpkgs != null) { nixpkgs = inputs.${server.nixpkgs}; }
    ) settings.servers;
  };
}
