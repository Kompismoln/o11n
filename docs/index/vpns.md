# `vpns`

Written by `o11n-dev index` from the options of an org that are declared in the part's code, as `dev/index.nix` reads
them, each by its place in `org.toml`, or, for a module that is in several places, once as a type, `<file>`, by its
place in that.

## Options

### `vpn.<name>.address`

`org/vpn.nix` · string matching the pattern ^[0-9a-f]{1,4}:[0-9a-f]{1,4}:[0-9a-f]{1,4}:[0-9a-f]{1,4}::/(64|128)$

Default: `"${prefix}::/${toString prefixLength}"`

ipv6 vpn address

### `vpn.<name>.address4`

`org/vpn.nix` · string matching the pattern ^[0-9]{1,3}.[0-9]{1,3}.[0-9]{1,3}.0/(24|32)$

Default: `"${prefix4}.0/${toString prefixLength4}"`

ipv4 vpn address

### `vpn.<name>.addressWithBrackets`

`org/vpn.nix` · string matching the pattern ^[[][0-9a-f]{1,4}:[0-9a-f]{1,4}:[0-9a-f]{1,4}:[0-9a-f]{1,4}::[]]/(64|128)$

Default: `"[${prefix}::]/${toString prefixLength}"`

ipv6 vpn address enclosed in square brackets

### `vpn.<name>.allowedTCPPorts`

`org/vpn.nix` · list of signed integer

Default: `[ ]`

force all peers to allow these tcp ports in the vpn

### `vpn.<name>.allowedUDPPorts`

`org/vpn.nix` · list of signed integer

Default: `[ ]`

force all peers to allow these udp ports in the vpn

### `vpn.<name>.dns`

`org/vpn.nix` · list of impossible (empty enum)

Default: `[ ]`

list of name servers

### `vpn.<name>.enable`

`org/vpn.nix` · boolean

Default: `true`

Whether to enable a wireguard vpn.

### `vpn.<name>.gateway`

`org/vpn.nix` · null or impossible (empty enum)

Default: `null`

designated gateway host, which a hub has and a mesh doesn't

### `vpn.<name>.id`

`org/vpn.nix` · signed integer

unique integer identifier for the vpn

### `vpn.<name>.ids`

`org/vpn.nix` · `<ids>`

Default: `{ int = id; }`

entity id in various formats

### `vpn.<name>.interface`

`org/vpn.nix` · string

Default: `"‹name›"`

interface for the vpn

### `vpn.<name>.keepalive`

`org/vpn.nix` · signed integer

Default: `25`

port allocated for the vpn

### `vpn.<name>.key`

`org/vpn.nix` · string

Default: `"${name}-key"`

the key each host on the vpn has for it, its wireguard key

### `vpn.<name>.members`

`org/vpn.nix` · attribute set of (submodule)

Default: each host whose `vpns` has the vpn, at `<prefix>::<host id>` and `<prefix4>.<host id>` as `<host>.<namespace>`,
and each service whose `vpn` it is, on each of those hosts it's on, at `<prefix>:ffff:<host id>:<uid>:<id>` as
`<service>-<host>.<namespace>`

what has an address in the vpn, by its name there: each host on it, and each service that serves on it, on each of those
hosts it's on

### `vpn.<name>.members.<name>.address`

`org/vpn.nix` · string

the member's ipv6 address

### `vpn.<name>.members.<name>.address4`

`org/vpn.nix` · null or string

Default: `null`

the member's ipv4 address, which only a host has

### `vpn.<name>.members.<name>.fqdn`

`org/vpn.nix` · string

the member's name

### `vpn.<name>.members.<name>.host`

`org/vpn.nix` · string

the host the member is on, whose wireguard key carries its traffic

### `vpn.<name>.members.<name>.id`

`org/vpn.nix` · string

the member's entity

### `vpn.<name>.members.<name>.key`

`org/vpn.nix` · null or string

Default: `null`

the member's own wireguard key, which only a host has

### `vpn.<name>.name`

`org/vpn.nix` · string

Default: `"‹name›"`

name of the vpn

### `vpn.<name>.namespace`

`org/vpn.nix` · string

top domain in the vpns

### `vpn.<name>.port`

`org/vpn.nix` · 16 bit unsigned integer; between 0 and 65535 (both inclusive)

Default: `51820 + id`

port allocated for the vpn

### `vpn.<name>.prefix`

`org/vpn.nix` · string matching the pattern ^[0-9a-f]{1,4}:[0-9a-f]{1,4}:[0-9a-f]{1,4}:[0-9a-f]{1,4}$

Default: `"${org.prefix}:${ids.hex4}"`

ipv6 prefix for peers in vpn

### `vpn.<name>.prefix4`

`org/vpn.nix` · string matching the pattern ^[0-9]{1,3}.[0-9]{1,3}.[0-9]{1,3}$

Default: `"${org.prefix4}.${toString id}"`

ipv4 prefix for peers in vpn

### `vpn.<name>.prefixLength`

`org/vpn.nix` · signed integer

Default: `64`

ipv6 prefix length for peers in vpn

### `vpn.<name>.prefixLength4`

`org/vpn.nix` · signed integer

Default: `24`

ipv4 prefix length for peers in vpn

### `vpn.<name>.proxy`

`org/vpn.nix` · boolean

Default: `false`

Whether to enable ipv6 proxy through gateway.

### `vpn.<name>.resetOnRebuild`

`org/vpn.nix` · boolean

Default: `true`

destroy and recreate network device post rebuild

### `vpn.<name>.topology`

`org/vpn.nix` · one of "hub", "mesh"

Default: `"hub"`

how the vpn's hosts peer: `hub`, each with the gateway alone, which forwards between them, or `mesh`, each with each, at
the endpoint of either

### `vpn.<name>.trusted`

`org/vpn.nix` · boolean

disable firewalls on this vpn
