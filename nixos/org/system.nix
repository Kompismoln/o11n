{
  host,
  lib,
  org,
  ...
}:
{
  # Policy: a host with an NVIDIA card runs NVIDIA's driver, which a desktop on nouveau has neither a hardware cursor
  # nor a picture without artifacts with.
  imports = lib.optional (lib.any (gpu: gpu.vendor == "nvidia") host.gpus) ../nvidia.nix;

  time.timeZone = org.timezone;
  i18n.defaultLocale = org.locale;
  system.stateVersion = host.stateVersion;
  networking.hostName = host.name;
  hardware.facter.reportPath = if host.hardwareReport == "facter" then host.facterFile else null;

  # Leaving out hardware conf entirely is likely a mistake that'll switch the system into an unreachable state.
  # The error NixOS raises if hostPlatform isn't set is a currently a useful signal that no hardware conf is loaded.
  #nixpkgs.hostPlatform = host.system;
}
// lib.optionalAttrs host.rescueMode {
  users.mutableUsers = false;
  users.users.root = {
    hashedPasswordFile = org.service.rescue.publicKeys.passwd;
    openssh.authorizedKeys.keyFiles = [
      org.service.rescue.publicKeys.ssh-key
    ];
  };
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = lib.mkForce "yes";
    };
  };
}
