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
    (map (disk: diskoConfigurations."${host.name}-${disk.name}") (lib.attrValues host.disk-layouts))
    ++ [
      {
        assertions = [
          {
            assertion = host.keys ? luks-key || config.boot.initrd.luks.devices == { };
            message = "${host.name}'s disk-layouts open luks devices (${toString (lib.attrNames config.boot.initrd.luks.devices)}) with its luks-key, which it only has with an encrypted disk: set encrypted = true on the disk whose layout encrypts it.";
          }
        ];
      }
      (lib.mkIf (host.keys ? luks-key) {
        sops.secrets.luks-key = { };

        boot.initrd.secrets."${host.luksKeyFile}" = config.sops.secrets.luks-key.path;
      })
    ]
  );

}
