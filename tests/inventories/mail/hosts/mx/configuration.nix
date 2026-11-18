{
  boot.loader.grub.device = "/dev/vda";

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  # Fact: nobody logs in to the inventory's hosts.
  users.allowNoPasswordLogin = true;
}
