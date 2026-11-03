# tests/vm/timeout.nix
# Policy: a VM test that hangs fails within minutes, rather than at the test driver's default of an
# hour; a guest that stops answering blocks the driver past any timeout of its own commands, so only
# globalTimeout ends it. A test sets a tighter one from how long it takes.
{ lib, ... }:
{
  globalTimeout = lib.mkDefault 600;
}
