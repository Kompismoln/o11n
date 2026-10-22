lib: {
  flake = lib.types.lazyAttrsOf lib.types.raw;
  spec = lib.types.lazyAttrsOf lib.types.anything;
}
