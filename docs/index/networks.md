# `networks`

Written by `o11n-dev index` from the options of an org that are declared in the part's code, as `dev/index.nix` reads
them, each by its place in `org.toml`, or, for a module that is in several places, once as a type, `<file>`, by its
place in that.

## Options

### `host.<name>.network.<name>.address`

`org/network.nix` · null or string

Default: `null`

ipv6 host address (not CIDR)

### `host.<name>.network.<name>.address4`

`org/network.nix` · null or string

Default: `null`

ipv4 host address

### `host.<name>.network.<name>.destination`

`org/network.nix` · null or string

Default: `null`

ipv6 destination

### `host.<name>.network.<name>.destination4`

`org/network.nix` · null or string

Default: `null`

ipv4 destination

### `host.<name>.network.<name>.dns`

`org/network.nix` · null or (list of string)

Default: `null`

name servers of the network

### `host.<name>.network.<name>.fqdn`

`org/network.nix` · null or string

Default: `null`

host's name in the network

### `host.<name>.network.<name>.gateway`

`org/network.nix` · null or string

Default: `null`

ipv6 gateway address

### `host.<name>.network.<name>.gateway4`

`org/network.nix` · null or string

Default: `null`

ipv4 gateway address

### `host.<name>.network.<name>.gatewayOnLink`

`org/network.nix` · null or boolean

Default: `null`

Whether to enable onlink for gateway.

### `host.<name>.network.<name>.interface`

`org/network.nix` · string

interface associated with the network

### `host.<name>.network.<name>.mac`

`org/network.nix` · null or string matching the pattern ^[0-9a-f]{2}(:[0-9a-f]{2}){5}$

Default: `null`

mac address

### `host.<name>.network.<name>.metric`

`org/network.nix` · null or signed integer

Default: `1024`

ipv6 metric for routing: lower takes priority

### `host.<name>.network.<name>.metric4`

`org/network.nix` · null or signed integer

Default: `1024`

ipv4 metric for routing: lower takes priority

### `host.<name>.network.<name>.mode`

`org/network.nix` · null or one of "dhcp", "static"

Default: `null`

how the interface gets its address, statically or by dhcp; null leaves it unconfigured

### `host.<name>.network.<name>.prefixLength`

`org/network.nix` · null or signed integer

Default: `null`

ipv6 prefix length

### `host.<name>.network.<name>.prefixLength4`

`org/network.nix` · null or signed integer

Default: `null`

ipv4 prefix length

### `host.<name>.network.<name>.principals`

`org/network.nix` · attribute set of (submodule)

Default: `{ }`

the address and name of each principal that has one in the network on this host, by its id

### `host.<name>.network.<name>.principals.<name>.address`

`org/network.nix` · string

the principal's ipv6 address on this host in the network

### `host.<name>.network.<name>.principals.<name>.fqdn`

`org/network.nix` · string

the principal's name on this host in the network

### `host.<name>.network.<name>.privacy`

`org/network.nix` · null or boolean

Default: `null`

Whether to enable ipv6 kernel address rotation.

### `host.<name>.network.<name>.suffix`

`org/network.nix` · null or string matching the pattern ::[0-9a-f]{1,4}(:[0-9a-f]{1,4}){0,3}

Default: `null`

the ipv6 interface identifier, as ::fba, that a dhcp network forms its address with from the prefix its router
advertises, rather than asking the router for one; null leaves it to the kernel and the router

### `host.<name>.network.<name>.type`

`org/network.nix` · string

Default: `"‹name›"`

network type

### `host.<name>.router.address4`

`org/router.nix` · string matching the pattern ^[0-9]{1,3}.[0-9]{1,3}.[0-9]{1,3}.[0-9]{1,3}$

Default: `"192.168.1.1"`

the router's IPv4 address on its lan, which o11n reaches it at where its name doesn't answer

### `host.<name>.router.dmz`

`org/router.nix` · null or impossible (empty enum)

Default: `null`

the host behind the router that what isn't forwarded otherwise is forwarded to on IPv4, or null

### `host.<name>.router.forwards`

`org/router.nix` · list of raw value

Default: each port that a host whose `behind` is the router listens on for its `vpns`, in the order of the hosts' names
and their vpns

the ports the router forwards, each `{ host, vpn, port }`: each port a host behind it listens on for its vpns

### `host.<name>.router.glesys`

`org/router.nix` · null or (submodule)

Default: `null`

the GleSYS account whose DNS the router keeps its WAN address in, as the A record of each of `records`, or null

### `host.<name>.router.glesys.account`

`org/router.nix` · string

the account, as GleSYS names it

### `host.<name>.router.glesys.key`

`org/router.nix` · string

Default: `"glesys-key"`

the host's secret that is the account's API key, which may update its DNS records

### `host.<name>.router.glesys.records`

`org/router.nix` · list of string matching the pattern [a-z0-9-]+\.[a-z0-9.-]+

Default: the `endpoint` of each host behind the router that has one

the names whose A record is the router's WAN address, each `<name>.<domain>` of a domain of the account's

### `host.<name>.router.lan`

`org/router.nix` · lazy attribute set of raw value

Default: for each host whose `behind` is the router, its one network with a `suffix`

for each host behind the router, the network the router reaches it on: its one network with a `suffix`, which has an
`address4`

### `host.<name>.router.prefixLength4`

`org/router.nix` · integer between 8 and 30 (both inclusive)

Default: `24`

the prefix length of the router's lan, which each host behind it has its address4 in
