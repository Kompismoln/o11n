# nixos/services/locksmith.nix
{
  config,
  host,
  lib,
  pkgs,
  ...
}:
let
  inherit (config.boot) loader;

  # Dependency: nixpkgs' boot loaders write the initrd's secrets under these, as locksmith.sh reads them.
  boot =
    if loader.systemd-boot.enable then
      {
        loader = "systemd-boot";
        dir =
          if loader.systemd-boot.xbootldrMountPoint != null then
            loader.systemd-boot.xbootldrMountPoint
          else
            loader.efi.efiSysMountPoint;
      }
    else if loader.grub.enable then
      {
        loader = "grub";
        dir = (lib.head loader.grub.mirroredBoots).path;
      }
    else
      {
        loader = "none";
        dir = "/boot";
      };

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
              pkgs.libarchive
              pkgs.sops
            ]
          } \
          --set KEY_FILE "${config.sops.age.keyFile}" \
          --set SYSTEM_PROFILE /nix/var/nix/profiles/system \
          --set CURRENT_SYSTEM /run/current-system \
          --set BOOT_LOADER ${boot.loader} \
          --set BOOT_DIR ${boot.dir} \
          --set INITRD_KEY_FILE ./.initrd-secrets/${lib.removePrefix "/" host.luksKeyFile} ${
            lib.optionalString (lib.length luksDevices == 1) "--set LUKS_DEVICE ${lib.head luksDevices}"
          }
      '';
in
{
  environment.systemPackages = [ locksmithPkg ];

  # Dependency: locksmith.sh revokes a host's old identities only once each of these opens without them.
  environment.etc."o11n/sops-files".text = lib.concatLines (
    lib.unique (map (secret: "${secret.sopsFile}") (lib.attrValues config.sops.secrets))
  );

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
