# Sizing and issue-deduplication policy tests for scripts/llm-radar.py, the
# script behind `task llm:radar` (#1020). The test loads its sibling
# llm-radar.py and patches `fetch`, so no leaderboard, Hugging Face or GitHub
# request is made and no model service is involved.
_: {
  perSystem =
    { pkgs, ... }:
    {
      checks.llm-radar =
        pkgs.runCommand "llm-radar-tests"
          {
            nativeBuildInputs = [ pkgs.python3 ];
          }
          ''
            cp ${../../scripts/llm-radar.py} llm-radar.py
            cp ${../../scripts/llm-radar-test.py} llm-radar-test.py
            python3 llm-radar-test.py
            touch "$out"
          '';
    };
}
