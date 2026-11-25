# Replay the production notifier against a stub journal and webhook, offline.
_: {
  perSystem =
    { pkgs, ... }:
    {
      checks.valheim-player-notify =
        pkgs.runCommand "valheim-player-notify-tests"
          {
            nativeBuildInputs = with pkgs; [
              bash
              coreutils
              gawk
              gnused
              jq
              python3
            ];
          }
          ''
            cp ${../apps/_valheim/player-notify.sh} player-notify.sh
            cp ${../apps/_valheim/player-notify-test.py} player-notify-test.py
            python3 player-notify-test.py
            touch "$out"
          '';
    };
}
