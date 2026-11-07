<<<<<<< signed
=======
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
>>>>>>> @stamp
