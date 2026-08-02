# nixos/disko.nix
{
  config,
  host,
  lib,
  o11nInputs,
  diskoConfigurations,
  ...
}:
{
  imports = [
    o11nInputs.disko.nixosModules.disko
    ../nixos/preserve.nix
  ];

  config = lib.mkMerge (
    (lib.attrValues diskoConfigurations)
    ++ [
      (lib.mkIf (diskoConfigurations != { }) {
        sops.secrets.luks-key = { };
        boot.initrd.secrets."${host.luksKeyFile}" = config.sops.secrets.luks-key.path;
      })
    ]
  );
}
