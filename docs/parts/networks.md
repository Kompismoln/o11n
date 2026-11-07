# Networks

A host's `network.<name>` is an interface it configures with networkd (`org/network.nix`, `nixos/org/networking.nix`),
by its `mode`: `static`, at its `address` and `address4`, or `dhcp`, as the router has it. Each of its vpns is a network
too, with no mode, which `nixos/org/wireguard.nix` configures (`docs/parts/vpns.md`).

## Suffix

A dhcp network with a `suffix` forms its IPv6 address from the prefix the router advertises and the suffix, and asks the
router for none, so that the address is the host's own for as long as the prefix lasts, whatever the router has of it:

```toml
[host.desktop]
network.eth = { interface = "enp5s0", mode = "dhcp", suffix = "::fba" }
network.wifi = { interface = "wlp4s0", mode = "dhcp" }
```

It still takes its IPv4 address by DHCP. A network that isn't dhcp, or has a suffix another network of the org has,
which could be on its link, fails evaluation.
