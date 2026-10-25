# nixos/org/state.nix
{
  config,
  lib,
  pkgs,
  org,
  ...
}:
let
  statePkg =
    user: _:
    pkgs.runCommand "state"
      {
        buildInputs = [ pkgs.makeWrapper ];
      }
      ''
          mkdir -p $out/bin
          cp ${./state.sh} $out/bin/state-unwrapped
          chmod +x $out/bin/state-unwrapped
          makeWrapper $out/bin/state-unwrapped $out/bin/state \
            --prefix PATH : ${
              lib.makeBinPath [
                pkgs.restic
              ]
            } \
        --set RESTIC_REPOSITORY "${config.users.users.${user}.home}/.restic" \
        --set RESTIC_PASSWORD_FILE "${config.sops.secrets."${user}/restic-key".path}"

      '';

  userMatchBlocks = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (user: _: ''
      Match User ${user}
        ForceCommand internal-sftp
        AllowTcpForwarding no
        X11Forwarding no
        AllowAgentForwarding no
        PermitTunnel no
    '') eachUser
  );
in
{
  sops.secrets = lib.mapAttrs' (
    user: userCfg:
    lib.nameValuePair "${user}/restic-key" {
      inherit (org.${userCfg.class}.${user}.secrets) sopsFile;
      owner = user;
      group = user;
    }
  ) eachUser;

  users.users = lib.mapAttrs (user: userCfg: {
    packages = [ (statePkg user userCfg) ];
  }) eachUser;

  services.openssh = {
    extraConfig = userMatchBlocks;
  };
}
