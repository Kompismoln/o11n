{
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  # The inventory has no users with keys; nobody logs in to this host.
  users.allowNoPasswordLogin = true;
}
