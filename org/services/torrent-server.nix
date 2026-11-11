{ lib, ... }:
{
  options = {
    upload = lib.mkOption {
      description = "the most the server uploads, in KiB/s, or null for no limit";
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
    };
    download = lib.mkOption {
      description = "the most the server downloads, in KiB/s, or null for no limit";
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
    };
    ratio = lib.mkOption {
      description = "the ratio of uploaded to downloaded a torrent seeds to, or null to seed for as long as it's there";
      type = lib.types.nullOr (lib.types.addCheck lib.types.number (ratio: ratio > 0));
      default = null;
    };
    peerPort = lib.mkOption {
      description = "the port the server takes peers on, TCP and UDP, which a router the host is behind forwards to it for peers to dial";
      type = lib.types.port;
      default = 51413;
    };
  };
}
