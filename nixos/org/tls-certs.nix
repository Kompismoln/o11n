# nixos/org/tls-certs.nix
{
  lib,
  org,
  ...
}:
let
  certs = map (namespace: org.certs.${namespace}) (
    lib.filter (namespace: org.certs ? ${namespace}) org.namespaces
  );
in
{
  config = lib.mkIf (org.namespaces != [ ]) {
    assertions = map (namespace: {
      assertion = org.certs ? ${namespace};
      message = "The hosts trust a tls-cert for each of the org's namespaces, and no service holds ${namespace}'s: declare [service.domain-${namespace}].";
    }) org.namespaces;

    security.pki.certificates = map (cert: builtins.readFile cert.publicKeys.tls-cert) certs;

    users.groups.tls-cert = {
      members = [
        "nginx"
        #"zitadel"
      ];
    };

    sops.secrets = lib.listToAttrs (
      map (cert: {
        name = "${cert.name}/tls-cert";
        value = {
          inherit (cert.secrets) sopsFile;
          owner = "root";
          group = "tls-cert";
          mode = "0440";
        };
      }) certs
    );
  };
}
