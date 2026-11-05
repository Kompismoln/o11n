{
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  # Accommodating for the inventory's users, who have no keys: nobody logs in to this host.
  users.allowNoPasswordLogin = true;
}
