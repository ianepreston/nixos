# Vibes - HM Simple Aspect
# Claude Code
_: {
  flake.modules.homeManager.vibes =
    { pkgs, inputs, ... }:
    let
      pkgsUnstable = import inputs.nixpkgs-unstable {
        inherit (pkgs.stdenv.hostPlatform) system;
        inherit (pkgs) config;
      };

      statusLine = pkgs.writeShellApplication {
        name = "claude-statusline";
        runtimeInputs = with pkgs; [
          jq
          git
          coreutils
        ];
        text = ''
          input=$(cat)
          model=$(jq -r '.model.display_name' <<<"$input")
          cwd=$(jq -r '.workspace.current_dir' <<<"$input")
          cost=$(jq -r '.cost.total_cost_usd // 0' <<<"$input")

          # context_window.* is populated by Claude Code from the most recent
          # API response, so the limit tracks the active model (200k vs 1M).
          # current_usage is null before the first API call and after /compact.
          pct=$(jq -r '.context_window.used_percentage // 0' <<<"$input" | cut -d. -f1)
          limit=$(jq -r '.context_window.context_window_size // 200000' <<<"$input")
          tokens=$(jq -r '
            (.context_window.current_usage // {}) as $u
            | ($u.input_tokens // 0)
              + ($u.cache_read_input_tokens // 0)
              + ($u.cache_creation_input_tokens // 0)
          ' <<<"$input")

          branch=$(git -C "$cwd" branch --show-current 2>/dev/null || true)
          dir=$(basename "$cwd")

          printf '%s | %s%s | ctx %d%% (%dk/%dk) | $%.2f' \
            "$model" "$dir" "''${branch:+ ($branch)}" \
            "$pct" "$(( tokens / 1000 ))" "$(( limit / 1000 ))" "$cost"
        '';
      };

      settings = (pkgs.formats.json { }).generate "claude-settings.json" {
        model = "opus";
        effortLevel = "high";
        theme = "light";
        agentPushNotifEnabled = true;
        statusLine = {
          type = "command";
          command = "${statusLine}/bin/claude-statusline";
        };
      };
    in
    {
      home.packages = builtins.attrValues {
        inherit (pkgsUnstable)
          claude-code
          gemini-cli
          worktrunk
          ;
      };

      home.file.".claude/settings.json".source = settings;
    };
}
