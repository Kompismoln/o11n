{
  boot.loader.grub.device = "/dev/vda";

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  # Accommodating for the mail server's certificate, which nothing else on mx accepts ACME's terms for.
  security.acme = {
    acceptTerms = true;
    defaults.email = "alice@example.com";
  };

  # Fact: nobody logs in to the inventory's hosts.
  users.allowNoPasswordLogin = true;
}
