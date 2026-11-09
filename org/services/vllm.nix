{
  context,
  lib,
  name,
  ...
}:
let
  host = name;

  server =
    { config, ... }:
    let
      # Fact: the org keeps a model's refs/main and chat_template.jinja from the host's Hugging Face cache here.
      details = "hosts/${host}/details/models--${lib.replaceStrings [ "/" ] [ "--" ] config.model}";

      # Policy: a file the store holds on its own, as a path in the org's files is, rather than a place in the org's
      # tree, whose every change would change the server.
      own =
        path:
        builtins.path {
          inherit path;
          name = builtins.unsafeDiscardStringContext (baseNameOf path);
        };
    in
    {
      options = {
        nixpkgs = lib.mkOption {
          description = "the org's input whose nixpkgs the server's vllm comes from, or null for the host's";
          type = lib.types.nullOr lib.types.str;
          default = null;
        };
        model = lib.mkOption {
          description = "the Hugging Face model ID the server serves";
          type = lib.types.str;
        };
        revision = lib.mkOption {
          description = "the model's commit in the host's Hugging Face cache";
          type = lib.types.nullOr lib.types.str;
          default =
            let
              ref = "${context.path}/${details}/refs/main";
            in
            if builtins.pathExists ref then builtins.readFile ref else null;
          defaultText = lib.literalMD "the org's `hosts/<host>/details/models--<org>--<name>/refs/main`, if it exists";
        };
        chatTemplate = lib.mkOption {
          description = "the chat template the server uses for every request, by the path of a file in the org";
          type = context.types.orgFile;
          default = "${details}/chat_template.jinja";
          apply = own;
          defaultText = lib.literalMD "the org's `hosts/<host>/details/models--<org>--<name>/chat_template.jinja`";
        };
        servedModelNames = lib.mkOption {
          description = "the names the server answers to";
          type = lib.types.listOf lib.types.str;
          default = [ ];
        };
        host = lib.mkOption {
          description = "the loopback address the server binds to, or any other to serve the host's vpns, on each of the host's addresses there";
          type = lib.types.str;
          default = "127.0.0.1";
        };
        port = lib.mkOption {
          description = "the port the server binds to";
          type = lib.types.port;
        };
        extraArgs = lib.mkOption {
          description = "vllm serve's further arguments";
          type = lib.types.listOf lib.types.str;
          default = [ ];
        };
        environment = lib.mkOption {
          description = "the server's further environment";
          type = lib.types.attrsOf lib.types.str;
          default = { };
        };
        allowedGPUs = lib.mkOption {
          description = "the GPUs the server may use";
          type = lib.types.listOf lib.types.int;
          default = [ 0 ];
        };
      };
    };
in
{
  options = {
    report = {
      enable = lib.mkEnableOption "an HTTP endpoint reporting what each server runs";
      host = lib.mkOption {
        description = "the loopback address the report binds to, or any other to serve the host's vpns, on each of the host's addresses there";
        type = lib.types.str;
        default = "127.0.0.1";
      };
      port = lib.mkOption {
        description = "the port the report binds to";
        type = lib.types.port;
        default = 12008;
      };
    };
    servers = lib.mkOption {
      description = "the vllm servers on the host, by name";
      type = lib.types.attrsOf (lib.types.submodule server);
      default = { };
    };
  };
}
