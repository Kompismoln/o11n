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
