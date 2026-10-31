# `org`

Written by `dev/index.py` from the options of an org that are declared in the part's code, as `dev/index.nix` reads
them, each by its place in `org.toml`.

## Options

### `app`

`org/default.nix` · attribute set of (submodule)

record of all apps

### `app.<name>.altpoints`

`org/app.nix` · list of string

Default: `[ ]`

alternative access points that should be redirected to endpoint

### `app.<name>.class`

`org/entity.nix` · one of "app", "host", "root", "service", "store", "user"

entity class

### `app.<name>.configurationFile`

`org/app.nix` · absolute path or string convertible to it

Default: `"apps/‹name›.nix"`

path to specific configuration

### `app.<name>.database`

`org/app.nix` · string

Default: `"‹name›"`

app's database

### `app.<name>.description`

`org/entity.nix` · string

Default: `"[app] ‹name›"`

full name or short purpose description

### `app.<name>.dump`

`org/app.nix` · null or string

Default: `null`

when to dump the app's database, as a systemd calendar event

### `app.<name>.endpoint`

`org/app.nix` · string

canonical name on internet

### `app.<name>.grants`

`org/entity.nix` · list of string

Default: `[ ]`

entity groups whose members get to decrypt the entity's secrets

### `app.<name>.id`

`org/entity.nix` · null or signed integer

Default: `null`

numeric internal id used to seed other id's

### `app.<name>.ids`

`org/entity.nix` · null or (submodule)

Default: `null`

entity id in various formats

### `app.<name>.ids.hex`

`org/ids.nix` · string matching the pattern ^[0-9a-f]{1,4}$

Default: `lib.toLower (lib.toHexString int)`

id as hex

### `app.<name>.ids.hex32`

`org/ids.nix` · string matching the pattern ^[0-9a-f]{32}$

Default: `lib.fixedWidthString 32 "0" hex`

id as hex with fixed length 32

### `app.<name>.ids.hex4`

`org/ids.nix` · string matching the pattern ^[0-9a-f]{4}$

Default: `lib.fixedWidthString 4 "0" hex`

id as hex with fixed length 4

### `app.<name>.ids.hex8`

`org/ids.nix` · string matching the pattern ^[0-9a-f]{8}$

Default: `lib.fixedWidthString 8 "0" hex`

id as hex with fixed length 8

### `app.<name>.ids.int`

`org/ids.nix` · signed integer

id

### `app.<name>.ids.str`

`org/ids.nix` · string

Default: `toString int`

id as string

### `app.<name>.location`

`org/app.nix` · string

Default: `"/"`

canonical path

### `app.<name>.name`

`org/entity.nix` · string

Default: `"‹name›"`

name

### `app.<name>.principal`

`org/entity.nix` · null or (submodule)

Default: `null`

optional attached principal

### `app.<name>.principal.bindAddress`

`org/principal.nix` · string matching the pattern
^[0-9a-f]{1,4}:[0-9a-f]{1,4}:[0-9a-f]{1,4}:[0-9a-f]{1,4}:(:[0-9a-f]{1,4}){1,3}$

Default: `"${org.loPrefix}::${toString uid}:${ids.hex4}"`

unique ipv6 loopback address for entity to bind to

### `app.<name>.principal.gid`

`org/principal.nix` · signed integer

Default: `uid`

posix group id

### `app.<name>.principal.groups`

`org/principal.nix` · list of string

Default: `[ ]`

principal's extra groups

### `app.<name>.principal.hasBash`

`org/principal.nix` · boolean

Default: `false`

Whether to enable force bash shell for non-normal users.

### `app.<name>.principal.hasHome`

`org/principal.nix` · boolean

Default: `true`

Whether to enable force bash shell for non-normal users.

### `app.<name>.principal.hasPasswd`

`org/principal.nix` · boolean

Default: `false`

Whether to enable endow entity with a password.

### `app.<name>.principal.hasPublicKey`

`org/principal.nix` · boolean

Default: `true`

Whether to enable endow entity with a cryptographic identity.

### `app.<name>.principal.hasSFTP`

`org/principal.nix` · boolean

Default: `true`

Whether to enable force bash shell for non-normal users.

### `app.<name>.principal.home`

`org/principal.nix` · string

Default: `"/var/lib/‹name›"`

endow entity with /home (for users) or /var/lib (for non-users)

### `app.<name>.principal.homeMode`

`org/principal.nix` · string

Default: `"0750"`

permissions of the principal's home

### `app.<name>.principal.members`

`org/principal.nix` · list of string

Default: `[ ]`

members of the principal's groups

### `app.<name>.principal.uid`

`org/principal.nix` · signed integer

Default: the block `org/classes.nix` gives the entity's class, plus the entity's `id`

posix user id

### `app.<name>.publicKeys`

`org/entity.nix` · submodule

paths to the entity's public keys, one for each key its class has

### `app.<name>.publicKeys.age-key`

`org/public-keys.nix` · absolute path

Default: `"<org>/public-keys/app-‹name›-age-key.pub"`

age-key path for app ‹name›

### `app.<name>.publicKeys.restic-key`

`org/public-keys.nix` · absolute path

Default: `"<org>/public-keys/app-‹name›-restic-key.pub"`

restic-key path for app ‹name›

### `app.<name>.publicKeys.secret-key`

`org/public-keys.nix` · absolute path

Default: `"<org>/public-keys/app-‹name›-secret-key.pub"`

secret-key path for app ‹name›

### `app.<name>.publicKeys.ssh-key`

`org/public-keys.nix` · absolute path

Default: `"<org>/public-keys/app-‹name›-ssh-key.pub"`

ssh-key path for app ‹name›

### `app.<name>.run-on-hosts`

`org/app.nix` · list of string

Default: `[ ]`

hosts that this app should run on

### `app.<name>.scheme`

`org/app.nix` · string

Default: `"https"`

http or https

### `app.<name>.secrets`

`org/entity.nix` · submodule

where the entity's secrets are, and the key that decrypts them

### `app.<name>.secrets.decryptionKey`

`org/secrets.nix` · string

Default: `"/keys/app-‹name›"`

path on the host to the age key that decrypts the entity's secrets

### `app.<name>.secrets.sopsFile`

`org/secrets.nix` · absolute path

Default: `"<org>/enc/app-‹name›.yaml"`

sops file holding the entity's secrets

### `app.<name>.settings`

`org/entity.nix` · attribute set of anything

Default: `{ }`

entity-specific options, passed through as-is to the entity's configuration

### `app.<name>.ssl`

`org/app.nix` · boolean

Default: `true`

let's encrypt and force https

### `app.<name>.url`

`org/app.nix` · string

Default: `"${scheme}://${endpoint}"`

public url including scheme

### `build-hosts`

`org/default.nix` · list of impossible (empty enum)

Default: `[ ]`

list of designated build hosts

### `class`

`org/default.nix` · attribute set of (submodule)

metadata for classes

### `class.<name>.keys`

`org/default.nix` · list of string

Default: `[ ]`

keys an entity of the class has

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

### `flake`

`org/default.nix` · attribute set of string

Default: `{ }`

flake that the hosts' nix registry calls o11n

### `host`

`org/default.nix` · attribute set of (submodule)

record of all hosts

### `host.<name>.boot`

`org/host.nix` · one of "grub", "systemd"

Default: `"systemd"`

boot method

### `host.<name>.class`

`org/entity.nix` · one of "app", "host", "root", "service", "store", "user"

entity class

### `host.<name>.configurationFile`

`org/host.nix` · absolute path

Default: `"<org>/hosts/‹name›/configuration.nix"`

path to specific configuration

### `host.<name>.description`

`org/entity.nix` · string

Default: `"[host] ‹name›"`

full name or short purpose description

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

### `host.<name>.grants`

`org/entity.nix` · list of string

Default: `[ ]`

entity groups whose members get to decrypt the entity's secrets

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

### `host.<name>.id`

`org/entity.nix` · null or signed integer

Default: `null`

numeric internal id used to seed other id's

### `host.<name>.ids`

`org/entity.nix` · null or (submodule)

Default: `null`

entity id in various formats

### `host.<name>.ids.hex`

`org/ids.nix` · string matching the pattern ^[0-9a-f]{1,4}$

Default: `lib.toLower (lib.toHexString int)`

id as hex

### `host.<name>.ids.hex32`

`org/ids.nix` · string matching the pattern ^[0-9a-f]{32}$

Default: `lib.fixedWidthString 32 "0" hex`

id as hex with fixed length 32

### `host.<name>.ids.hex4`

`org/ids.nix` · string matching the pattern ^[0-9a-f]{4}$

Default: `lib.fixedWidthString 4 "0" hex`

id as hex with fixed length 4

### `host.<name>.ids.hex8`

`org/ids.nix` · string matching the pattern ^[0-9a-f]{8}$

Default: `lib.fixedWidthString 8 "0" hex`

id as hex with fixed length 8

### `host.<name>.ids.int`

`org/ids.nix` · signed integer

id

### `host.<name>.ids.str`

`org/ids.nix` · string

Default: `toString int`

id as string

### `host.<name>.luksKeyFile`

`org/host.nix` · string

Default: `"/luks-key"`

path in the initrd to the key that unlocks the host's luks devices

### `host.<name>.monitors`

`org/host.nix` · list of attribute set of anything

Default: `[ ]`

list of monitors possibly connected to the host

### `host.<name>.name`

`org/entity.nix` · string

Default: `"‹name›"`

name

### `host.<name>.network`

`org/host.nix` · attribute set of (submodule)

Default: `{ }`

networks to configure on host

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

### `host.<name>.network.<name>.privacy`

`org/network.nix` · null or boolean

Default: `null`

Whether to enable ipv6 kernel address rotation.

### `host.<name>.network.<name>.type`

`org/network.nix` · string

Default: `"‹name›"`

network type

### `host.<name>.principal`

`org/entity.nix` · null or (submodule)

Default: `null`

optional attached principal

### `host.<name>.principal.bindAddress`

`org/principal.nix` · string matching the pattern
^[0-9a-f]{1,4}:[0-9a-f]{1,4}:[0-9a-f]{1,4}:[0-9a-f]{1,4}:(:[0-9a-f]{1,4}){1,3}$

Default: `"${org.loPrefix}::${toString uid}:${ids.hex4}"`

unique ipv6 loopback address for entity to bind to

### `host.<name>.principal.gid`

`org/principal.nix` · signed integer

Default: `uid`

posix group id

### `host.<name>.principal.groups`

`org/principal.nix` · list of string

Default: `[ ]`

principal's extra groups

### `host.<name>.principal.hasBash`

`org/principal.nix` · boolean

Default: `false`

Whether to enable force bash shell for non-normal users.

### `host.<name>.principal.hasHome`

`org/principal.nix` · boolean

Default: `false`

Whether to enable force bash shell for non-normal users.

### `host.<name>.principal.hasPasswd`

`org/principal.nix` · boolean

Default: `false`

Whether to enable endow entity with a password.

### `host.<name>.principal.hasPublicKey`

`org/principal.nix` · boolean

Default: `false`

Whether to enable endow entity with a cryptographic identity.

### `host.<name>.principal.hasSFTP`

`org/principal.nix` · boolean

Default: `false`

Whether to enable force bash shell for non-normal users.

### `host.<name>.principal.home`

`org/principal.nix` · string

Default: `"/var/empty"`

endow entity with /home (for users) or /var/lib (for non-users)

### `host.<name>.principal.homeMode`

`org/principal.nix` · string

Default: `"0750"`

permissions of the principal's home

### `host.<name>.principal.members`

`org/principal.nix` · list of string

Default: `[ ]`

members of the principal's groups

### `host.<name>.principal.uid`

`org/principal.nix` · signed integer

Default: the block `org/classes.nix` gives the entity's class, plus the entity's `id`

posix user id

### `host.<name>.publicKeys`

`org/entity.nix` · submodule

paths to the entity's public keys, one for each key its class has

### `host.<name>.publicKeys.age-key`

`org/public-keys.nix` · absolute path

Default: `"<org>/public-keys/host-‹name›-age-key.pub"`

age-key path for host ‹name›

### `host.<name>.publicKeys.luks-key`

`org/public-keys.nix` · absolute path

Default: `"<org>/public-keys/host-‹name›-luks-key.pub"`

luks-key path for host ‹name›

### `host.<name>.publicKeys.ssh-key`

`org/public-keys.nix` · absolute path

Default: `"<org>/public-keys/host-‹name›-ssh-key.pub"`

ssh-key path for host ‹name›

### `host.<name>.publicKeys.wg0-key`

`org/public-keys.nix` · absolute path

Default: `"<org>/public-keys/host-‹name›-wg0-key.pub"`

wg0-key path for host ‹name›

### `host.<name>.publicKeys.wg1-key`

`org/public-keys.nix` · absolute path

Default: `"<org>/public-keys/host-‹name›-wg1-key.pub"`

wg1-key path for host ‹name›

### `host.<name>.publicKeys.wg2-key`

`org/public-keys.nix` · absolute path

Default: `"<org>/public-keys/host-‹name›-wg2-key.pub"`

wg2-key path for host ‹name›

### `host.<name>.reach`

`org/host.nix` · lazy attribute set of (null or raw value)

Default: `{ }`

each host's network on the first vpn it shares with this host, in the order of this host's vpns, or null

### `host.<name>.rescueMode`

`org/host.nix` · boolean

Default: `false`

Whether to enable insecure rescue mode..

### `host.<name>.roles`

`org/host.nix` · list of impossible (empty enum)

Default: `[ ]`

roles that this host has

### `host.<name>.secrets`

`org/entity.nix` · submodule

where the entity's secrets are, and the key that decrypts them

### `host.<name>.secrets.decryptionKey`

`org/secrets.nix` · string

Default: `"/keys/host-‹name›"`

path on the host to the age key that decrypts the entity's secrets

### `host.<name>.secrets.sopsFile`

`org/secrets.nix` · absolute path

Default: `"<org>/enc/host-‹name›.yaml"`

sops file holding the entity's secrets

### `host.<name>.settings`

`org/entity.nix` · attribute set of anything

Default: `{ }`

entity-specific options, passed through as-is to the entity's configuration

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

### `mailserver.dkimSelector`

`org/mailserver.nix` · string

dkim selector

### `mailserver.endpoint`

`org/mailserver.nix` · string

Default: `"example.com"`

endpoint

### `mailserver.ext`

`org/mailserver.nix` · string

external name

### `mailserver.host`

`org/mailserver.nix` · string

host

### `mailserver.int`

`org/mailserver.nix` · string

internal name

### `name`

`org/default.nix` · string

name for organisation

### `namespaces`

`org/default.nix` · list of string

Default: `[ endpoint ]`

namespaces for hosts in the organisation

### `ops`

`org/default.nix` · attribute set of attribute set of list of string

Default: `{ }`

operations per entity groups

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

### `public-artifacts`

`org/default.nix` · attribute set of string

Default: `{ }`

path templates for public artifacts

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

### `secrets`

`org/default.nix` · attribute set of string

Default: `{ }`

path templates for secrets

### `service`

`org/default.nix` · attribute set of (submodule)

record of all services

### `service.<name>.class`

`org/entity.nix` · one of "app", "host", "root", "service", "store", "user"

entity class

### `service.<name>.data`

`org/service.nix` · attribute set of anything

Default: `{ }`

arbitrary data to service

### `service.<name>.description`

`org/entity.nix` · string

Default: `"[service] ‹name›"`

full name or short purpose description

### `service.<name>.endpoint`

`org/service.nix` · null or string

Default: `null`

maybe canonical name on internet

### `service.<name>.grants`

`org/entity.nix` · list of string

Default: `[ ]`

entity groups whose members get to decrypt the entity's secrets

### `service.<name>.id`

`org/entity.nix` · null or signed integer

Default: `null`

numeric internal id used to seed other id's

### `service.<name>.ids`

`org/entity.nix` · null or (submodule)

Default: `null`

entity id in various formats

### `service.<name>.ids.hex`

`org/ids.nix` · string matching the pattern ^[0-9a-f]{1,4}$

Default: `lib.toLower (lib.toHexString int)`

id as hex

### `service.<name>.ids.hex32`

`org/ids.nix` · string matching the pattern ^[0-9a-f]{32}$

Default: `lib.fixedWidthString 32 "0" hex`

id as hex with fixed length 32

### `service.<name>.ids.hex4`

`org/ids.nix` · string matching the pattern ^[0-9a-f]{4}$

Default: `lib.fixedWidthString 4 "0" hex`

id as hex with fixed length 4

### `service.<name>.ids.hex8`

`org/ids.nix` · string matching the pattern ^[0-9a-f]{8}$

Default: `lib.fixedWidthString 8 "0" hex`

id as hex with fixed length 8

### `service.<name>.ids.int`

`org/ids.nix` · signed integer

id

### `service.<name>.ids.str`

`org/ids.nix` · string

Default: `toString int`

id as string

### `service.<name>.name`

`org/entity.nix` · string

Default: `"‹name›"`

name

### `service.<name>.principal`

`org/entity.nix` · null or (submodule)

Default: `null`

optional attached principal

### `service.<name>.principal.bindAddress`

`org/principal.nix` · string matching the pattern
^[0-9a-f]{1,4}:[0-9a-f]{1,4}:[0-9a-f]{1,4}:[0-9a-f]{1,4}:(:[0-9a-f]{1,4}){1,3}$

Default: `"${org.loPrefix}::${toString uid}:${ids.hex4}"`

unique ipv6 loopback address for entity to bind to

### `service.<name>.principal.gid`

`org/principal.nix` · signed integer

Default: `uid`

posix group id

### `service.<name>.principal.groups`

`org/principal.nix` · list of string

Default: `[ ]`

principal's extra groups

### `service.<name>.principal.hasBash`

`org/principal.nix` · boolean

Default: `false`

Whether to enable force bash shell for non-normal users.

### `service.<name>.principal.hasHome`

`org/principal.nix` · boolean

Default: `false`

Whether to enable force bash shell for non-normal users.

### `service.<name>.principal.hasPasswd`

`org/principal.nix` · boolean

Default: `false`

Whether to enable endow entity with a password.

### `service.<name>.principal.hasPublicKey`

`org/principal.nix` · boolean

Default: `true`

Whether to enable endow entity with a cryptographic identity.

### `service.<name>.principal.hasSFTP`

`org/principal.nix` · boolean

Default: `false`

Whether to enable force bash shell for non-normal users.

### `service.<name>.principal.home`

`org/principal.nix` · string

Default: `"/var/empty"`

endow entity with /home (for users) or /var/lib (for non-users)

### `service.<name>.principal.homeMode`

`org/principal.nix` · string

Default: `"0750"`

permissions of the principal's home

### `service.<name>.principal.members`

`org/principal.nix` · list of string

Default: `[ ]`

members of the principal's groups

### `service.<name>.principal.uid`

`org/principal.nix` · signed integer

Default: the block `org/classes.nix` gives the entity's class, plus the entity's `id`

posix user id

### `service.<name>.publicKeys`

`org/entity.nix` · submodule

paths to the entity's public keys, one for each key its class has

### `service.<name>.publicKeys.age-key`

`org/public-keys.nix` · absolute path

Default: `"<org>/public-keys/service-‹name›-age-key.pub"`

age-key path for service ‹name›

### `service.<name>.publicKeys.mail`

`org/public-keys.nix` · absolute path

Default: `"<org>/public-keys/service-‹name›-mail.pub"`

mail path for service ‹name›

### `service.<name>.publicKeys.nix-sign`

`org/public-keys.nix` · absolute path

Default: `"<org>/public-keys/service-‹name›-nix-sign.pub"`

nix-sign path for service ‹name›

### `service.<name>.publicKeys.passwd`

`org/public-keys.nix` · absolute path

Default: `"<org>/public-keys/service-‹name›-passwd.sha512"`

passwd path for service ‹name›

### `service.<name>.publicKeys.secret-key`

`org/public-keys.nix` · absolute path

Default: `"<org>/public-keys/service-‹name›-secret-key.pub"`

secret-key path for service ‹name›

### `service.<name>.publicKeys.ssh-key`

`org/public-keys.nix` · absolute path

Default: `"<org>/public-keys/service-‹name›-ssh-key.pub"`

ssh-key path for service ‹name›

### `service.<name>.publicKeys.tls-cert`

`org/public-keys.nix` · absolute path

Default: `"<org>/public-keys/service-‹name›-tls-cert.pem"`

tls-cert path for service ‹name›

### `service.<name>.secrets`

`org/entity.nix` · submodule

where the entity's secrets are, and the key that decrypts them

### `service.<name>.secrets.decryptionKey`

`org/secrets.nix` · string

Default: `"/keys/service-‹name›"`

path on the host to the age key that decrypts the entity's secrets

### `service.<name>.secrets.sopsFile`

`org/secrets.nix` · absolute path

Default: `"<org>/enc/service-‹name›.yaml"`

sops file holding the entity's secrets

### `service.<name>.settings`

`org/entity.nix` · attribute set of anything

Default: `{ }`

entity-specific options, passed through as-is to the entity's configuration

### `store`

`org/default.nix` · attribute set of (submodule)

record of all stores

### `store.<name>.class`

`org/entity.nix` · one of "app", "host", "root", "service", "store", "user"

entity class

### `store.<name>.description`

`org/entity.nix` · string

Default: `"[store] ‹name›"`

full name or short purpose description

### `store.<name>.grants`

`org/entity.nix` · list of string

Default: `[ ]`

entity groups whose members get to decrypt the entity's secrets

### `store.<name>.id`

`org/entity.nix` · null or signed integer

Default: `null`

numeric internal id used to seed other id's

### `store.<name>.ids`

`org/entity.nix` · null or (submodule)

Default: `null`

entity id in various formats

### `store.<name>.ids.hex`

`org/ids.nix` · string matching the pattern ^[0-9a-f]{1,4}$

Default: `lib.toLower (lib.toHexString int)`

id as hex

### `store.<name>.ids.hex32`

`org/ids.nix` · string matching the pattern ^[0-9a-f]{32}$

Default: `lib.fixedWidthString 32 "0" hex`

id as hex with fixed length 32

### `store.<name>.ids.hex4`

`org/ids.nix` · string matching the pattern ^[0-9a-f]{4}$

Default: `lib.fixedWidthString 4 "0" hex`

id as hex with fixed length 4

### `store.<name>.ids.hex8`

`org/ids.nix` · string matching the pattern ^[0-9a-f]{8}$

Default: `lib.fixedWidthString 8 "0" hex`

id as hex with fixed length 8

### `store.<name>.ids.int`

`org/ids.nix` · signed integer

id

### `store.<name>.ids.str`

`org/ids.nix` · string

Default: `toString int`

id as string

### `store.<name>.name`

`org/entity.nix` · string

Default: `"‹name›"`

name

### `store.<name>.principal`

`org/entity.nix` · null or (submodule)

Default: `null`

optional attached principal

### `store.<name>.principal.bindAddress`

`org/principal.nix` · string matching the pattern
^[0-9a-f]{1,4}:[0-9a-f]{1,4}:[0-9a-f]{1,4}:[0-9a-f]{1,4}:(:[0-9a-f]{1,4}){1,3}$

Default: `"${org.loPrefix}::${toString uid}:${ids.hex4}"`

unique ipv6 loopback address for entity to bind to

### `store.<name>.principal.gid`

`org/principal.nix` · signed integer

Default: `uid`

posix group id

### `store.<name>.principal.groups`

`org/principal.nix` · list of string

Default: `[ ]`

principal's extra groups

### `store.<name>.principal.hasBash`

`org/principal.nix` · boolean

Default: `false`

Whether to enable force bash shell for non-normal users.

### `store.<name>.principal.hasHome`

`org/principal.nix` · boolean

Default: `true`

Whether to enable force bash shell for non-normal users.

### `store.<name>.principal.hasPasswd`

`org/principal.nix` · boolean

Default: `false`

Whether to enable endow entity with a password.

### `store.<name>.principal.hasPublicKey`

`org/principal.nix` · boolean

Default: `true`

Whether to enable endow entity with a cryptographic identity.

### `store.<name>.principal.hasSFTP`

`org/principal.nix` · boolean

Default: `true`

Whether to enable force bash shell for non-normal users.

### `store.<name>.principal.home`

`org/principal.nix` · string

Default: `"/var/lib/‹name›"`

endow entity with /home (for users) or /var/lib (for non-users)

### `store.<name>.principal.homeMode`

`org/principal.nix` · string

Default: `"0750"`

permissions of the principal's home

### `store.<name>.principal.members`

`org/principal.nix` · list of string

Default: `[ ]`

members of the principal's groups

### `store.<name>.principal.uid`

`org/principal.nix` · signed integer

Default: the block `org/classes.nix` gives the entity's class, plus the entity's `id`

posix user id

### `store.<name>.publicKeys`

`org/entity.nix` · submodule

paths to the entity's public keys, one for each key its class has

### `store.<name>.publicKeys.age-key`

`org/public-keys.nix` · absolute path

Default: `"<org>/public-keys/store-‹name›-age-key.pub"`

age-key path for store ‹name›

### `store.<name>.publicKeys.ssh-key`

`org/public-keys.nix` · absolute path

Default: `"<org>/public-keys/store-‹name›-ssh-key.pub"`

ssh-key path for store ‹name›

### `store.<name>.secrets`

`org/entity.nix` · submodule

where the entity's secrets are, and the key that decrypts them

### `store.<name>.secrets.decryptionKey`

`org/secrets.nix` · string

Default: `"/keys/store-‹name›"`

path on the host to the age key that decrypts the entity's secrets

### `store.<name>.secrets.sopsFile`

`org/secrets.nix` · absolute path

Default: `"<org>/enc/store-‹name›.yaml"`

sops file holding the entity's secrets

### `store.<name>.settings`

`org/entity.nix` · attribute set of anything

Default: `{ }`

entity-specific options, passed through as-is to the entity's configuration

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

`org/default.nix` · attribute set of (submodule)

record of all users

### `user.<name>.class`

`org/entity.nix` · one of "app", "host", "root", "service", "store", "user"

entity class

### `user.<name>.description`

`org/entity.nix` · string

Default: `"[user] ‹name›"`

full name or short purpose description

### `user.<name>.email`

`org/user.nix` · null or string

Default: `null`

user's email address

### `user.<name>.grants`

`org/entity.nix` · list of string

Default: `[ ]`

entity groups whose members get to decrypt the entity's secrets

### `user.<name>.id`

`org/entity.nix` · null or signed integer

Default: `null`

numeric internal id used to seed other id's

### `user.<name>.ids`

`org/entity.nix` · null or (submodule)

Default: `null`

entity id in various formats

### `user.<name>.ids.hex`

`org/ids.nix` · string matching the pattern ^[0-9a-f]{1,4}$

Default: `lib.toLower (lib.toHexString int)`

id as hex

### `user.<name>.ids.hex32`

`org/ids.nix` · string matching the pattern ^[0-9a-f]{32}$

Default: `lib.fixedWidthString 32 "0" hex`

id as hex with fixed length 32

### `user.<name>.ids.hex4`

`org/ids.nix` · string matching the pattern ^[0-9a-f]{4}$

Default: `lib.fixedWidthString 4 "0" hex`

id as hex with fixed length 4

### `user.<name>.ids.hex8`

`org/ids.nix` · string matching the pattern ^[0-9a-f]{8}$

Default: `lib.fixedWidthString 8 "0" hex`

id as hex with fixed length 8

### `user.<name>.ids.int`

`org/ids.nix` · signed integer

id

### `user.<name>.ids.str`

`org/ids.nix` · string

Default: `toString int`

id as string

### `user.<name>.inboxes`

`org/user.nix` · list of string

Default: `[ ]`

mail addresses delivered to the user's mailbox, as the mail server's aliases

### `user.<name>.mail`

`org/user.nix` · boolean

Default: `false`

Whether to enable internal mail.

### `user.<name>.name`

`org/entity.nix` · string

Default: `"‹name›"`

name

### `user.<name>.principal`

`org/entity.nix` · null or (submodule)

Default: `null`

optional attached principal

### `user.<name>.principal.bindAddress`

`org/principal.nix` · string matching the pattern
^[0-9a-f]{1,4}:[0-9a-f]{1,4}:[0-9a-f]{1,4}:[0-9a-f]{1,4}:(:[0-9a-f]{1,4}){1,3}$

Default: `"${org.loPrefix}::${toString uid}:${ids.hex4}"`

unique ipv6 loopback address for entity to bind to

### `user.<name>.principal.gid`

`org/principal.nix` · signed integer

Default: `uid`

posix group id

### `user.<name>.principal.groups`

`org/principal.nix` · list of string

Default: `[ ]`

principal's extra groups

### `user.<name>.principal.hasBash`

`org/principal.nix` · boolean

Default: `true`

Whether to enable force bash shell for non-normal users.

### `user.<name>.principal.hasHome`

`org/principal.nix` · boolean

Default: `true`

Whether to enable force bash shell for non-normal users.

### `user.<name>.principal.hasPasswd`

`org/principal.nix` · boolean

Default: `true`

Whether to enable endow entity with a password.

### `user.<name>.principal.hasPublicKey`

`org/principal.nix` · boolean

Default: `true`

Whether to enable endow entity with a cryptographic identity.

### `user.<name>.principal.hasSFTP`

`org/principal.nix` · boolean

Default: `false`

Whether to enable force bash shell for non-normal users.

### `user.<name>.principal.home`

`org/principal.nix` · string

Default: `"/home/‹name›"`

endow entity with /home (for users) or /var/lib (for non-users)

### `user.<name>.principal.homeMode`

`org/principal.nix` · string

Default: `"0750"`

permissions of the principal's home

### `user.<name>.principal.members`

`org/principal.nix` · list of string

Default: `[ ]`

members of the principal's groups

### `user.<name>.principal.uid`

`org/principal.nix` · signed integer

Default: the block `org/classes.nix` gives the entity's class, plus the entity's `id`

posix user id

### `user.<name>.publicKeys`

`org/entity.nix` · submodule

paths to the entity's public keys, one for each key its class has

### `user.<name>.publicKeys.age-key`

`org/public-keys.nix` · absolute path

Default: `"<org>/public-keys/user-‹name›-age-key.pub"`

age-key path for user ‹name›

### `user.<name>.publicKeys.mail`

`org/public-keys.nix` · absolute path

Default: `"<org>/public-keys/user-‹name›-mail.pub"`

mail path for user ‹name›

### `user.<name>.publicKeys.passwd`

`org/public-keys.nix` · absolute path

Default: `"<org>/public-keys/user-‹name›-passwd.sha512"`

passwd path for user ‹name›

### `user.<name>.publicKeys.restic-key`

`org/public-keys.nix` · absolute path

Default: `"<org>/public-keys/user-‹name›-restic-key.pub"`

restic-key path for user ‹name›

### `user.<name>.publicKeys.ssh-key`

`org/public-keys.nix` · absolute path

Default: `"<org>/public-keys/user-‹name›-ssh-key.pub"`

ssh-key path for user ‹name›

### `user.<name>.secrets`

`org/entity.nix` · submodule

where the entity's secrets are, and the key that decrypts them

### `user.<name>.secrets.decryptionKey`

`org/secrets.nix` · string

Default: `"/keys/user-‹name›"`

path on the host to the age key that decrypts the entity's secrets

### `user.<name>.secrets.sopsFile`

`org/secrets.nix` · absolute path

Default: `"<org>/enc/user-‹name›.yaml"`

sops file holding the entity's secrets

### `user.<name>.settings`

`org/entity.nix` · attribute set of anything

Default: `{ }`

entity-specific options, passed through as-is to the entity's configuration

### `vpn`

`org/default.nix` · attribute set of (submodule)

Default: `{ }`

attrset of vpn configurations

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

`org/vpn.nix` · submodule

Default: `{ int = id; }`

entity id in various formats

### `vpn.<name>.ids.hex`

`org/ids.nix` · string matching the pattern ^[0-9a-f]{1,4}$

Default: `lib.toLower (lib.toHexString int)`

id as hex

### `vpn.<name>.ids.hex32`

`org/ids.nix` · string matching the pattern ^[0-9a-f]{32}$

Default: `lib.fixedWidthString 32 "0" hex`

id as hex with fixed length 32

### `vpn.<name>.ids.hex4`

`org/ids.nix` · string matching the pattern ^[0-9a-f]{4}$

Default: `lib.fixedWidthString 4 "0" hex`

id as hex with fixed length 4

### `vpn.<name>.ids.hex8`

`org/ids.nix` · string matching the pattern ^[0-9a-f]{8}$

Default: `lib.fixedWidthString 8 "0" hex`

id as hex with fixed length 8

### `vpn.<name>.ids.int`

`org/ids.nix` · signed integer

id

### `vpn.<name>.ids.str`

`org/ids.nix` · string

Default: `toString int`

id as string

### `vpn.<name>.interface`

`org/vpn.nix` · string

Default: `"‹name›"`

interface for the vpn

### `vpn.<name>.keepalive`

`org/vpn.nix` · signed integer

Default: `25`

port allocated for the vpn

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
