# packages/gost.nix
#
# gost, with a PHT client that dials a server whose name doesn't resolve where it runs,
# as in a Claude cloud session, where only the HTTP proxy resolves names.
{ gost }:
gost.overrideAttrs (old: {
  postConfigure = (old.postConfigure or "") + ''
    chmod -R u+w vendor/github.com/go-gost/x/internal/util/pht
    patch -p1 -d vendor/github.com/go-gost/x < ${./gost-pht-dial-by-name.patch}
  '';
})
