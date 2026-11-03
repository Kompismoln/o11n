{
  root = {
    keys = {
      age-key = "age";
    };
  };
  host = {
    block = 0;
    keys = {
      age-key = "age";
      ssh-key = "ssh";
    };
  };
  user = {
    block = 1000;
    keys = {
      age-key = "age";
      ssh-key = "ssh";
      passwd = "password";
      restic-key = "passphrase";
      archive-passwd = "htpasswd";
    };
  };
  service = {
    block = 2000;
    keys = {
      age-key = "age";
      ssh-key = "ssh";
      passwd = "password";
    };
  };
  app = {
    block = 3000;
    keys = {
      age-key = "age";
      ssh-key = "ssh";
      restic-key = "passphrase";
      archive-passwd = "htpasswd";
    };
  };
  store = {
    block = 4000;
    keys = {
      age-key = "age";
      ssh-key = "ssh";
    };
  };
}
