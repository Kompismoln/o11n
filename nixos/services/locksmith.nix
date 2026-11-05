# nixos/services/locksmith.nix
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Dependency: disko's partition label, as disk-layouts/ set it, is the luks device locksmith.sh opens.
  luksDevices = map (partition: "/dev/disk/by-partlabel/${partition.label}") (
    lib.filter (partition: (partition.content.type or null) == "luks") (
      lib.concatMap (disk: lib.attrValues (disk.content.partitions or { })) (
        lib.attrValues (config.disko.devices.disk or { })
      )
    )
  );

  locksmithPkg =
    pkgs.runCommand "locksmith"
      {
        buildInputs = [ pkgs.makeWrapper ];
      }
      ''
        mkdir -p $out/bin
        cp ${./locksmith.sh} $out/bin/locksmith-unwrapped
        chmod +x $out/bin/locksmith-unwrapped

        makeWrapper $out/bin/locksmith-unwrapped $out/bin/locksmith \
          --prefix PATH : ${
            lib.makeBinPath [
              pkgs.cryptsetup
              pkgs.age
            ]
          } \
          --set KEY_FILE "${config.sops.age.keyFile}" ${
            lib.optionalString (lib.length luksDevices == 1) "--set LUKS_DEVICE ${lib.head luksDevices}"
          }
      '';
in
{
  environment.systemPackages = [ locksmithPkg ];

  services.openssh = {
    extraConfig = ''
      Match User locksmith
        ForceCommand sudo ${locksmithPkg}/bin/locksmith \$SSH_ORIGINAL_COMMAND
    '';
  };

  security.sudo.extraRules = [
    {
      users = [ "locksmith" ];
      commands = [
        {
          command = "${locksmithPkg}/bin/locksmith *";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];
}
