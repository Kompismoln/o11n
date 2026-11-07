{
  o11nInputs,
  host,
  ...
}:
{
  imports = [
    o11nInputs.sops-nix.nixosModules.sops
  ];

  sops = {
    defaultSopsFile = host.secrets.sopsFile;
    age = {
      keyFile = host.secrets.decryptionKey;
      sshKeyPaths = [ ];
    };
    gnupg.sshKeyPaths = [ ];
  };
}
