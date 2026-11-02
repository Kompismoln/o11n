# nixos/org/snapshot.nix
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.o11n.snapshots;

  snapshot = pkgs.writeShellApplication {
    name = "state-snapshot";
    runtimeInputs = [
      pkgs.btrfs-progs
      pkgs.coreutils
      pkgs.util-linux
    ]
    ++ lib.optional config.boot.zfs.enabled config.boot.zfs.package;
    text = ''
      id=$1
      case $id in
      ${lib.concatStrings (
        lib.mapAttrsToList (id: data: "${lib.escapeShellArg id}) data=${lib.escapeShellArg data} ;;\n") cfg
      )}
      *)
        echo "state-snapshot: $id has no state on this host" >&2
        exit 1
        ;;
      esac
      [[ -d $data ]] || {
        echo "state-snapshot: $id's state, $data, isn't there" >&2
        exit 1
      }
      link=/run/o11n/state/$id
      mkdir -p /run/o11n/state
      # Policy: no one replaces an entity's snapshot while state-archive@, which holds the lock, reads it.
      exec 9>"$link.lock"
      flock 9

      # Policy: one snapshot an entity, of the subvolume or dataset its state is on, replaced as the next one is taken.
      case $(findmnt -n -o FSTYPE -T "$data") in
      btrfs)
        root=$data
        # Fact: a btrfs subvolume's root is inode 256.
        until [[ $(stat -c %i "$root") == 256 ]]; do
          [[ $root != / ]] || {
            echo "state-snapshot: $data is in no btrfs subvolume this host mounts" >&2
            exit 1
          }
          root=$(dirname "$root")
        done
        dir=$root/.state
        mkdir -p "$dir"
        chmod 0700 "$dir"
        if [[ -e $dir/$id.new ]]; then btrfs subvolume delete "$dir/$id.new"; fi
        btrfs subvolume snapshot -r "$root" "$dir/$id.new"
        if [[ -e $dir/$id ]]; then btrfs subvolume delete "$dir/$id"; fi
        mv "$dir/$id.new" "$dir/$id"
        target=$dir/$id''${data#"$root"}
        ;;
      zfs)
        dataset=$(findmnt -n -o SOURCE -T "$data")
        mount=$(findmnt -n -o TARGET -T "$data")
        name=state-$id
        if zfs list -H "$dataset@$name.new" &>/dev/null; then zfs destroy "$dataset@$name.new"; fi
        zfs snapshot "$dataset@$name.new"
        if zfs list -H "$dataset@$name" &>/dev/null; then zfs destroy "$dataset@$name"; fi
        zfs rename "$dataset@$name.new" "$dataset@$name"
        target=$mount/.zfs/snapshot/$name''${data#"$mount"}
        ;;
      *)
        echo "state-snapshot: $data is on neither btrfs nor zfs, so $id's state is as it is"
        target=$data
        ;;
      esac
      ln -sfn "$target" "$link"
      echo "state-snapshot: $link is $target"
    '';
  };
in
{
  options.o11n.snapshots = lib.mkOption {
    description = "each entity's state on the host, by its id, which state-snapshot@<id> snapshots and links at /run/o11n/state/<id>";
    default = { };
    type = with lib.types; attrsOf str;
  };

  config = lib.mkIf (cfg != { }) {
    systemd.services."state-snapshot@" = {
      description = "snapshot %i's state";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${lib.getExe snapshot} %i";
      };
    };
  };
}
