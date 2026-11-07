{
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  # Accommodating for the inventory, which has no users: nobody logs in to this host.
  users.allowNoPasswordLogin = true;
}
