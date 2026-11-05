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
    };
  };
  user = {
    block = 1000;
    # Dependency: `o11n as` and `o11n ssh` log in with a user's ssh-key, whether or not it's a principal.
    keys = {
      age-key = "age";
      ssh-key = "ssh";
    };
  };
  service = {
    block = 2000;
    keys = {
      age-key = "age";
    };
  };
  app = {
    block = 3000;
    keys = {
      age-key = "age";
    };
  };
  store = {
    block = 4000;
    keys = {
      age-key = "age";
    };
  };
}
