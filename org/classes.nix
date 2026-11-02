{
  root = {
    keys = [ "age-key" ];
  };
  host = {
    block = 0;
    keys = [
      "age-key"
      "ssh-key"
      "wg0-key"
      "wg1-key"
      "wg2-key"
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
      "archive-passwd"
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
      "archive-passwd"
    ];
  };
  store = {
    block = 4000;
    keys = [
      "age-key"
      "ssh-key"
    ];
  };
}
