# `org`

Written by `o11n-dev index` from the options of an org that are declared in the part's code, as `dev/index.nix` reads
them, each by its place in `org.toml`, or, for a module that is in several places, once as a type, `<file>`, by its
place in that.

## Options

### `allotment`

`org/default.nix` · attribute set of (submodule)

Default: `{ }`

record of all allotments, each by <handle>@<host>: room on a host for a principal

### `app`

`org/default.nix` · attribute set of (`<entity>` and its own options)

record of all apps

### `app.<name>.altpoints`

`org/app.nix` · list of string

Default: `[ ]`

alternative access points that should be redirected to endpoint

### `app.<name>.collabora`

`org/app.nix` · null or (submodule)

Default: `null`

the app's settings as a collabora, which make it one

### `app.<name>.collabora.allowedHosts`

`org/apps/collabora.nix` · list of string

Default: `[ ]`

the hosts collabora accepts WOPI from

### `app.<name>.configurationFile`

`org/app.nix` · null or (absolute path or string convertible to it)

Default: the org's `apps/<name>.nix`, if it exists

the org's own configuration of the app, beside its kind's, or null

### `app.<name>.database`

`org/app.nix` · string

Default: `"‹name›"`

app's database

### `app.<name>.django`

`org/app.nix` · null or (submodule)

Default: `null`

the app's settings as a django, which make it one

### `app.<name>.django.input`

`org/apps/django.nix` · string

Default: `name`

the org's input whose packages.<system> has the app's django-app and scripts

### `app.<name>.django.locationProxy`

`org/apps/django.nix` · string

Default: `"/"`

the nginx location that django serves, the rest being static

### `app.<name>.django.module`

`org/apps/django.nix` · string

the app's django module

### `app.<name>.django.timeout`

`org/apps/django.nix` · signed integer

Default: `30`

gunicorn's timeout, in seconds

### `app.<name>.django.trustedOrigins`

`org/apps/django.nix` · list of string

Default: `[ ]`

django's CSRF_TRUSTED_ORIGINS

### `app.<name>.endpoint`

`org/app.nix` · string

canonical name on internet

### `app.<name>.jitsi`

`org/app.nix` · null or (submodule)

Default: `null`

the app's settings as a jitsi, which make it one

### `app.<name>.jitsi.keycloak`

`org/apps/jitsi.nix` · impossible (empty enum)

the keycloak app jitsi authenticates with

### `app.<name>.jitsi.realm`

`org/apps/jitsi.nix` · string

the keycloak realm of jitsi's client

### `app.<name>.keycloak`

`org/app.nix` · null or (submodule)

Default: `null`

the app's settings as a keycloak, which make it one

### `app.<name>.kind`

`org/app.nix` · null or one of "collabora", "django", "jitsi", "keycloak", "mobilizon", "nextcloud", "nextcloud-rolf",
"wordpress"

Default: the one of its kinds' tables that is set, or null

the kind of the app, whose configuration in o11n's nixos/apps/ it gets: the one of its kinds' tables that is set, or
null

### `app.<name>.location`

`org/app.nix` · string

Default: `"/"`

canonical path

### `app.<name>.mobilizon`

`org/app.nix` · null or (submodule)

Default: `null`

the app's settings as a mobilizon, which make it one

### `app.<name>.mobilizon.from`

`org/apps/mobilizon.nix` · string

Default: `principal.mail.address`

the address mobilizon's mail is from, which its principal sends as

### `app.<name>.mobilizon.input`

`org/apps/mobilizon.nix` · string

Default: `name`

the org's input whose packages.<system>.default is the app's mobilizon

### `app.<name>.nextcloud`

`org/app.nix` · null or (submodule)

Default: `null`

the app's settings as a nextcloud, which make it one

### `app.<name>.nextcloud-rolf`

`org/app.nix` · null or (submodule)

Default: `null`

the app's settings as a nextcloud-rolf, which make it one

### `app.<name>.nextcloud-rolf.input`

`org/apps/nextcloud-rolf.nix` · string

Default: `name`

the org's input whose packages.<system> has the site's packages

### `app.<name>.nextcloud-rolf.nextcloud`

`org/apps/nextcloud-rolf.nix` · impossible (empty enum)

the nextcloud app whose files the site is built from, and whose user builds it

### `app.<name>.nextcloud.collabora`

`org/apps/nextcloud.nix` · null or impossible (empty enum)

Default: `null`

the collabora app whose endpoint nextcloud's office uses, or null

### `app.<name>.nextcloud.keycloak`

`org/apps/nextcloud.nix` · null or impossible (empty enum)

Default: `null`

the keycloak app nextcloud's users log in with, or null for nextcloud's own logins alone

### `app.<name>.nextcloud.realm`

`org/apps/nextcloud.nix` · string

Default: `""`

the keycloak realm of nextcloud's client

### `app.<name>.run-on-hosts`

`org/app.nix` · list of string

Default: `[ ]`

hosts that this app should run on

### `app.<name>.scheme`

`org/app.nix` · string

Default: `"https"`

http or https

### `app.<name>.ssl`

`org/app.nix` · boolean

Default: `true`

let's encrypt and force https

### `app.<name>.url`

`org/app.nix` · string

Default: `"${scheme}://${endpoint}"`

public url including scheme

### `app.<name>.wordpress`

`org/app.nix` · null or (submodule)

Default: `null`

the app's settings as a wordpress, which make it one

### `build-hosts`

`org/default.nix` · list of impossible (empty enum)

Default: `[ ]`

list of designated build hosts

### `certs`

`org/default.nix` · attribute set of raw value

Default: each service whose `namespace` isn't null, by it

the service that holds each namespace's tls-cert, by namespace

### `contact`

`org/default.nix` · string

Default: `"info@${endpoint}"`

contact

### `domain`

`org/default.nix` · attribute set of (submodule)

Default: `{ }`

domains managed by organisation

### `domain.<name>.mailbox`

`org/domain.nix` · boolean

Default: `false`

Whether to enable mailbox.

### `domain.<name>.name`

`org/domain.nix` · string

Default: `"‹name›"`

domain name

### `endpoint`

`org/default.nix` · string

canonical name on internet

### `entities`

`org/default.nix` · lazy attribute set of raw value

Default: each of `host`, `user`, `service`, `app` and `store` by its `handle`

every host, user, service, app and store, by its handle

### `host`

`org/default.nix` · attribute set of (`<entity>` and its own options)

record of all hosts

### `host.<name>.allotments`

`org/host.nix` · list of raw value

Default: the org's `allotment`s whose `host` is the host, in the order of their name

the allotments on the host

<<<<<<< signed
=======
### `host.<name>.behind`

`org/host.nix` · null or impossible (empty enum)

Default: `null`

the router whose NAT the host is behind, a host with `openwrt`, which forwards to it the ports it listens on for its
vpns, or null

>>>>>>> @stamp
### `host.<name>.boot`

`org/host.nix` · one of "grub", "systemd"

Default: `"systemd"`

boot method

### `host.<name>.configurationFile`

`org/host.nix` · absolute path

Default: `"<org>/hosts/‹name›/configuration.nix"`

path to specific configuration

### `host.<name>.desktop`

`org/host.nix` · attribute set of anything

Default: `{ }`

attrset of desktop settings

### `host.<name>.devices`

`org/host.nix` · list of attribute set of anything

Default: `[ ]`

list of devices possibly connected to the host

### `host.<name>.disk-layouts`

`org/host.nix` · attribute set of (submodule)

Default: `{ }`

record of disk layouts that applies to host

### `host.<name>.disk-layouts.<name>.devices`

`org/disk.nix` · string or list of string

unix path to device(s)

### `host.<name>.disk-layouts.<name>.encrypted`

`org/disk.nix` · boolean

Default: `true` but for the `single-xfs` and `raid1-xfs` layouts

whether the layout encrypts the disk with the host's luks-key

### `host.<name>.disk-layouts.<name>.layout`

`org/disk.nix` · string

layout in disk-layouts/ that partitions the disk

### `host.<name>.disk-layouts.<name>.mountpoint`

`org/disk.nix` · null or string

Default: `null`

where the layout mounts the disk, for a layout that takes one

### `host.<name>.disk-layouts.<name>.name`

`org/disk.nix` · string

Default: `"‹name›"`

name of the disk in disko

### `host.<name>.endpoint`

`org/host.nix` · null or string

Default: `null`

maybe canonical name on internet

### `host.<name>.facterFile`

`org/host.nix` · absolute path

Default: `"<org>/hosts/‹name›/facter.json"`

facter report path

### `host.<name>.hardwareReport`

`org/host.nix` · one of "standard", "facter"

Default: `"facter"`

hardware report method

### `host.<name>.home`

`org/host.nix` · attribute set of (submodule)

Default: `{ }`

list of home configurations for a user

### `host.<name>.home.<name>.configurationFile`

`org/home.nix` · absolute path

Default: `"<org>/homes/‹name›@‹name›.nix"`

path to specific configuration

### `host.<name>.home.<name>.hostname`

`org/home.nix` · string

Default: `"‹name›"`

host the home is on

### `host.<name>.home.<name>.name`

`org/home.nix` · string

Default: `"‹name›@‹name›"`

name of the home configuration

### `host.<name>.home.<name>.roles`

`org/home.nix` · list of string

Default: `[ ]`

roles the home has

### `host.<name>.home.<name>.stateVersion`

`org/home.nix` · null or string

Default: `null`

nixos state version

### `host.<name>.home.<name>.username`

`org/home.nix` · string

Default: `"‹name›"`

user the home belongs to

### `host.<name>.luksKeyFile`

`org/host.nix` · string

Default: `"/luks-key"`

path in the initrd to the key that unlocks the host's luks devices

### `host.<name>.monitors`

`org/host.nix` · list of attribute set of anything

Default: `[ ]`

list of monitors possibly connected to the host

### `host.<name>.network`

`org/host.nix` · attribute set of (submodule)

Default: `{ }`

networks to configure on host

<<<<<<< signed
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
=======
### `host.<name>.nixos`
>>>>>>> @stamp

<<<<<<< signed
### `host.<name>.network.<name>.principals.<name>.fqdn`
=======
`org/host.nix` · boolean
>>>>>>> @stamp

<<<<<<< signed
`org/network.nix` · string
=======
Default: `openwrt == null`
>>>>>>> @stamp

<<<<<<< signed
the principal's name on this host in the network
=======
whether o11n builds the host's NixOS system, rather than only its keys, vpns and homes
>>>>>>> @stamp

<<<<<<< signed
### `host.<name>.network.<name>.privacy`
=======
### `host.<name>.openwrt`
>>>>>>> @stamp

<<<<<<< signed
`org/network.nix` · null or boolean
=======
`org/host.nix` · null or (submodule)
>>>>>>> @stamp

Default: `null`

<<<<<<< signed
Whether to enable ipv6 kernel address rotation.

### `host.<name>.network.<name>.type`

`org/network.nix` · string

Default: `"‹name›"`

network type

### `host.<name>.nixos`

`org/host.nix` · boolean

Default: `true`

whether o11n builds the host's NixOS system, rather than only its keys, vpns and homes
=======
the OpenWrt the host runs, as a router, or null
>>>>>>> @stamp

### `host.<name>.principals`

`org/host.nix` · list of raw value

Default: the host's `users`, the apps whose `run-on-hosts` has it, and the `services` and `stores` of its `roles`, but
for those without a principal, in the order of their `handle`

the principals on the host: its users, the apps that run on it, and its roles' services and stores

### `host.<name>.reach`

`org/host.nix` · lazy attribute set of (null or raw value)

Default: `{ }`

each host's network on the first vpn it shares with this host, in the order of this host's vpns, or null

### `host.<name>.replicas`

`org/host.nix` · list of raw value

Default: the org's `allotment`s whose `replicas` have the host, in the order of their name

the allotments the host keeps a replica of

### `host.<name>.rescueMode`

`org/host.nix` · boolean

Default: `false`

Whether to enable insecure rescue mode..

### `host.<name>.roles`

`org/host.nix` · list of impossible (empty enum)

Default: `[ ]`

roles that this host has

### `host.<name>.services`

`org/host.nix` · list of raw value

Default: the `services` of its `roles`, in the order of their name

the services of the host's roles, whose configuration it imports

<<<<<<< signed
=======
### `host.<name>.shares`

`org/host.nix` · lazy attribute set of (null or string)

Default: for each host, the first of this host's `vpns` that is in its `vpns`, or `null`

each host's first vpn it shares with this host, in the order of this host's vpns, or null

>>>>>>> @stamp
### `host.<name>.stateVersion`

`org/host.nix` · null or string

Default: `null`

nixos state version

### `host.<name>.system`

`org/host.nix` · string

host platform

### `host.<name>.users`

`org/host.nix` · list of impossible (empty enum)

Default: `[ ]`

users

### `host.<name>.vpns`

`org/host.nix` · list of impossible (empty enum)

Default: `[ ]`

list of interface names for vpns

### `loCidr`

`org/default.nix` · string matching the pattern ^[0-9a-f]{1,4}:[0-9a-f]{1,4}:[0-9a-f]{1,4}:[0-9a-f]{1,4}::/(64|128)$

Default: `"${loPrefix}::/${toString prefixLength}"`

CIDR route of loPrefix

### `loPrefix`

`org/default.nix` · string matching the pattern ^[0-9a-f]{1,4}:[0-9a-f]{1,4}:[0-9a-f]{1,4}:[0-9a-f]{1,4}$

Default: `"${prefix}:ffff"`

ULA reserved for host-local service addresses on lo

### `locale`

`org/default.nix` · string

default locale

### `mailserver`

`org/default.nix` · null or (submodule)

Default: `null`

main mailserver

### `name`

`org/default.nix` · string

name for organisation

### `namespaces`

`org/default.nix` · list of string

Default: `[ endpoint ]`

namespaces for hosts in the organisation

### `postgres`

`org/default.nix` · string matching the pattern [0-9]+

postgresql major version of every server and client

### `prefix`

`org/default.nix` · string matching the pattern ^[0-9a-f]{1,4}:[0-9a-f]{1,4}:[0-9a-f]{1,4}$

ipv6 private prefix

### `prefix4`

`org/default.nix` · string matching the pattern ^[0-9]{1,3}.[0-9]{1,3}$

ipv4 private prefix

### `prefixLength`

`org/default.nix` · signed integer

Default: `64`

ipv6 private prefix length

### `prefixLength4`

`org/default.nix` · signed integer

Default: `24`

ipv4 private prefix length

### `repository`

`org/default.nix` · attribute set of string

Default: `{ }`

the organisation's own flake, where the remote builder fetches its revisions

### `role`

`org/default.nix` · attribute set of (submodule)

Default: `{ }`

role declaration

### `role.<name>.name`

`org/role.nix` · string

Default: `"‹name›"`

domain name

### `role.<name>.services`

`org/role.nix` · list of impossible (empty enum)

Default: `[ ]`

services bundled in this role

### `role.<name>.stores`

`org/role.nix` · list of impossible (empty enum)

Default: `[ ]`

stores bundled in this role

### `root`

`org/default.nix` · attribute set of anything

Default: `{ }`

attrs of root identities

### `root-identities`

`org/default.nix` · list of string

Default:

```nix
[
  "root-0"
  "root-1"
]
```

list of root identities

### `service`

`org/default.nix` · attribute set of (`<entity>` and its own options)

record of all services

### `service.<name>.configurationFile`

`org/service.nix` · null or absolute path

Default: o11n's `nixos/services/<name>.nix`, or else the org's `services/<name>.nix`, if either exists

the configuration a host with the service imports, or null

### `service.<name>.data`

`org/service.nix` · attribute set of anything

Default: `{ }`

arbitrary data to service

### `service.<name>.endpoint`

`org/service.nix` · null or string

Default: `null`

maybe canonical name on internet

### `service.<name>.hosts`

`org/service.nix` · attribute set of attribute set of anything

Default: `{ }`

the service's settings on each host it's on, which its configuration reads, typed by o11n's org/services/<name>.nix when
that exists

### `service.<name>.namespace`

`org/service.nix` · null or string

Default: `<namespace>` for the service `domain-<namespace>`, of a namespace in the org's `namespaces` or a vpn's
`namespace`, or else `null`

the namespace whose tls-cert the service holds, for it and its subdomains, or null

### `service.<name>.vpn`

`org/service.nix` · null or impossible (empty enum)

Default: `null`

the vpn the service serves on, at its address on each host it's on, or null

### `store`

`org/default.nix` · attribute set of (`<entity>`)

record of all stores

### `storePath`

`org/default.nix` · absolute path

Default: `"<org>"`

nix store path to org as a package

### `theme`

`org/default.nix` · null or (submodule)

Default: `null`

colors, wallpaper and fonts

### `theme.colors`

`org/theme.nix` · attribute set of string

Default: `{ }`

flat color mapping with semantic colors attached

### `theme.fonts`

`org/theme.nix` · attribute set of (submodule)

fonts by their use

### `theme.fonts.<name>.name`

`org/theme.nix` · string

font name

### `theme.fonts.<name>.package`

`org/theme.nix` · string

font package

### `theme.vim-colorscheme`

`org/theme.nix` · null or string

Default: `null`

name of vim colorscheme to use (check nixvim for supported schemes)

### `theme.wallpaper`

`org/theme.nix` · string

path to wallpaper

### `timezone`

`org/default.nix` · string

timezone

### `user`

`org/default.nix` · attribute set of (`<entity>` and its own options)

record of all users

### `user.<name>.email`

`org/user.nix` · null or string

Default: `null`

user's email address

### `vpn`

`org/default.nix` · attribute set of (submodule)

Default: `{ }`

attrset of vpn configurations
<<<<<<< signed

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

`org/vpn.nix` · impossible (empty enum)

designated gateway host

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

### `vpn.<name>.trusted`

`org/vpn.nix` · boolean

disable firewalls on this vpn
=======
>>>>>>> @stamp

## Types

### `<entity>`

`org/entity.nix`

had by `app.<name>`, `host.<name>`, `service.<name>`, `store.<name>`, `user.<name>`

### `<entity>.actors`

`org/entity.nix` · list of (one of "root-0", "root-1")

Default: `[ ]`

the users and root identities that may act as the entity: its identity is encrypted to them and to the root identities

### `<entity>.class`

`org/entity.nix` · one of "app", "host", "root", "service", "store", "user"

entity class

### `<entity>.description`

`org/entity.nix` · string

Default: `"[${class}] ${name}"`

full name or short purpose description

### `<entity>.grants`

`org/entity.nix` · list of string

Default: `[ ]`

entity groups whose members get to decrypt the entity's secrets

### `<entity>.handle`

`org/entity.nix` · string

Default: `"${class}-${name}"`

the entity's handle, as o11n, the org's files and its other entities name it

### `<entity>.id`

`org/entity.nix` · null or signed integer

Default: `null`

numeric internal id used to seed other id's

### `<entity>.ids`

`org/entity.nix` · null or (`<ids>`)

Default: `{ int = id; }`, or `null` without an `id`

entity id in various formats

### `<entity>.keys`

`org/entity.nix` · attribute set of (one of "age", "ssh", "wireguard", "nix-sign", "tls-cert", "syncthing", "password",
"htpasswd", "luks", "passphrase", "file")

Default: the `keys` `org/classes.nix` gives the entity's class, an age-key, and a user an ssh-key; a principal's
`passwd` with `hasPasswd` and its `ssh-key` with `hasPublicKey`; a host's vpn `key` for each of its `vpns`, and its
`luks-key` if one of its `disk-layouts` is `encrypted`; the keys its principal's `mail` and `state` give it; a service's
`tls-cert` with a `namespace`, a host's `syncthing-<id>` for each allotment it has or keeps a replica of, and the keys
o11n's modules read of the services they name

the entity's keys, each with its type: its class's, those its configuration adds, and those the org declares for it

### `<entity>.name`

`org/entity.nix` · string

Default: `"‹name›"`

name

### `<entity>.principal`

`org/entity.nix` · null or (`<principal>`)

Default: `{ }` for an entity with an `id` but a host, or else `null`

optional attached principal

### `<entity>.publicKeys`

`org/entity.nix` · attribute set of absolute path

Default: `<org>/public-keys/<class>-<name>-<key>.<ext>` for each of its `keys`, `<ext>` being `pem` for a tls-cert,
`sha512` for a passwd, `htpasswd` for an archive-passwd and `pub` for the rest

paths to the entity's public keys, one for each of its keys

### `<entity>.secrets`

`org/entity.nix` · `<secrets>`

where the entity's secrets are, and the key that decrypts them

### `<entity>.settings`

`org/entity.nix` · attribute set of anything

Default: `{ }`

entity-specific options, passed through as-is to the entity's configuration

### `<ids>`

`org/ids.nix`

had by `<entity>.ids`, `vpn.<name>.ids`

### `<ids>.hex`

`org/ids.nix` · string matching the pattern ^[0-9a-f]{1,4}$

Default: `lib.toLower (lib.toHexString int)`

id as hex

### `<ids>.hex32`

`org/ids.nix` · string matching the pattern ^[0-9a-f]{32}$

Default: `lib.fixedWidthString 32 "0" hex`

id as hex with fixed length 32

### `<ids>.hex4`

`org/ids.nix` · string matching the pattern ^[0-9a-f]{4}$

Default: `lib.fixedWidthString 4 "0" hex`

id as hex with fixed length 4

### `<ids>.hex8`

`org/ids.nix` · string matching the pattern ^[0-9a-f]{8}$

Default: `lib.fixedWidthString 8 "0" hex`

id as hex with fixed length 8

### `<ids>.int`

`org/ids.nix` · signed integer

id

### `<ids>.str`

`org/ids.nix` · string

Default: `toString int`

id as string

### `<principal>`

`org/principal.nix`

had by `<entity>.principal`

### `<principal>.bindAddress`

`org/principal.nix` · string matching the pattern
^[0-9a-f]{1,4}:[0-9a-f]{1,4}:[0-9a-f]{1,4}:[0-9a-f]{1,4}:(:[0-9a-f]{1,4}){1,3}$

Default: `"${org.loPrefix}::${toString uid}:${ids.hex4}"`

unique ipv6 loopback address for entity to bind to

### `<principal>.gid`

`org/principal.nix` · signed integer

Default: `uid`

posix group id

### `<principal>.groups`

`org/principal.nix` · list of string

Default: `[ ]`

principal's extra groups

### `<principal>.hasBash`

`org/principal.nix` · boolean

Default: true for a user

Whether to enable force bash shell for non-normal users.

### `<principal>.hasHome`

`org/principal.nix` · boolean

Default: true for a user, store or app

Whether to enable endow entity with a home.

### `<principal>.hasPasswd`

`org/principal.nix` · boolean

Default: true for a user

Whether to enable endow entity with a password.

### `<principal>.hasPublicKey`

`org/principal.nix` · boolean

Default: true for a user, service, store or app

Whether to enable endow entity with a cryptographic identity.

### `<principal>.hasSFTP`

`org/principal.nix` · boolean

Default: true for an app or store

Whether to enable restrict the entity's ssh logins to sftp.

### `<principal>.home`

`org/principal.nix` · string

Default: `/home/<name>` for a user and `/var/lib/<name>` for the rest, if it `hasHome`, or else `/var/empty`

endow entity with /home (for users) or /var/lib (for non-users)

### `<principal>.homeMode`

`org/principal.nix` · string

Default: `"0750"`

permissions of the principal's home

### `<principal>.mail`

`org/principal.nix` · `<mail>`

Default: `{ }`

the principal's mail

### `<principal>.members`

`org/principal.nix` · list of string

Default: `[ ]`

members of the principal's groups

### `<principal>.state`

`org/principal.nix` · null or (`<state>`)

Default: `{ }` for a principal with a `home`, or else `null`

the settings of the principal's state, its home, which only a principal with a home has

### `<principal>.uid`

`org/principal.nix` · signed integer

Default: the block `org/classes.nix` gives the entity's class, plus the entity's `id`

posix user id
