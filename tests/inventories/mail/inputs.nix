{ pkgs }:
{
  calendar.packages.${pkgs.stdenv.hostPlatform.system}.default = pkgs.mobilizon;
}
