{
  root = {
    keys = [ "age-key" ];
  };
  org = {
    keys = [ "age-key" ];
  };
  host = {
    block = 0;
    keys = [
      "age-key"
      "ssh-key"
      "luks-key"
    ];
  };
  user = {
    block = 1000;
    keys = [
      "age-key"
      "ssh-key"
      "mail"
      "passwd"
      "restic-key"
    ];
  };
  service = {
    block = 2000;
    keys = [
      "age-key"
      "ssh-key"
      "mail"
      "passwd"
      "secret-key"
      "tls-cert"
      "nix-sign"
    ];
  };
  app = {
    block = 3000;
    keys = [
      "age-key"
      "ssh-key"
      "secret-key"
      "restic-key"
    ];
  };
  store = {
    block = 4000;
    keys = [
      "age-key"
    ];
  };
  network = {
    keys = [
      "age-key"
      "wg-key"
    ];
  };
  domain = {
    keys = [
      "age-key"
      "wg-key"
    ];
  };
  diskLayout = {
    keys = [
      "age-key"
      "luks-key"
    ];
  };
  home = {
    keys = [
      "age-key"
      "luks-key"
    ];
  };
}
