# What a test of tests/inventories/mail runs its hosts with, in a network without the internet's ACME or wg0.
{
  pkgs,
  o11nInputs,
  outputs,
}:
let
  inherit (pkgs) lib;
  inherit (outputs.org.mailserver) endpoint;
  fqdn = "mail.${endpoint}";
  elsewhere = "elsewhere.test";
  receiver = "mx.${elsewhere}";
  # Fact: the endpoints of the apps that are served over https in a test, whose certificates the test's CA signs.
  apps = [ outputs.org.app.cloud.endpoint ];
in
rec {
  inherit fqdn elsewhere receiver;

  tls = pkgs.runCommand "mail-test-tls" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir $out
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj /CN=test-ca \
      -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign \
      -keyout ca.key -out $out/ca.crt
    openssl req -newkey rsa:2048 -nodes -subj /CN=${fqdn} -keyout $out/mail.key -out mail.csr
    printf 'subjectAltName=DNS:${fqdn},DNS:${receiver}\n' > ext
    openssl x509 -req -in mail.csr -CA $out/ca.crt -CAkey ca.key -CAcreateserial -days 3650 \
      -extfile ext -out $out/mail.crt
    for app in ${lib.concatStringsSep " " apps}; do
      openssl req -newkey rsa:2048 -nodes -subj /CN=$app -keyout $out/$app.key -out $app.csr
      printf 'subjectAltName=DNS:%s\n' $app > ext
      openssl x509 -req -in $app.csr -CA $out/ca.crt -CAkey ca.key -CAcreateserial -days 3650 \
        -extfile ext -out $out/$app.crt
    done
  '';

  # Accommodating for sops-nix, which refuses a key file in the store: the inventory's committed
  # root identity, which reads every secret, is installed outside it.
  inventorySecrets = {
    imports = [ o11nInputs.sops-nix.nixosModules.sops ];
    system.activationScripts = {
      inventory-age-key = lib.stringAfter [ "specialfs" ] ''
        install -m 400 ${outputs.context.path}/keys/root-1 /run/inventory-age-key
      '';
      setupSecrets.deps = [ "inventory-age-key" ];
    };
    sops.age = {
      keyFile = lib.mkForce "/run/inventory-age-key";
      sshKeyPaths = [ ];
    };
  };

  # Accommodating for the test's network, which has no ACME server and no DNSSEC.
  mailserver = {
    mailserver = {
      localDnsResolver = false;
      x509 = {
        useACMEHost = lib.mkForce null;
        certificateFile = "${tls}/mail.crt";
        privateKeyFile = "${tls}/mail.key";
      };
    };
    security.acme.certs = lib.mkForce { };
    services.postfix-tlspol.configurePostfix = lib.mkForce false;
    virtualisation.memorySize = 2048;
    virtualisation.cores = 2;
  };

  # Duplication: as nixos/org/principals.nix makes them.
  principal = entity: {
    users.users.${entity.name} = {
      isSystemUser = true;
      group = entity.name;
      inherit (entity.principal) uid home homeMode;
      createHome = entity.principal.home != "/var/empty";
    };
    users.groups.${entity.name} = {
      inherit (entity.principal) gid;
      members = [ entity.name ] ++ entity.principal.members;
    };
  };
}
