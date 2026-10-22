{ inputs, ... }:
{
  imports = [ inputs.test-input.nixosModules.default ];
}
