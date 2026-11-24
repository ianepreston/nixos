# Disposable-fixture tests for scripts/skill-adapters.py (#1033): missing,
# orphaned, wrong-target and stale adapters, plus the current tree. The tree
# check itself also runs as the `skill-adapters` pre-commit hook. Nothing here
# proves Claude or Codex discovers the skills at runtime.
_: {
  perSystem =
    { pkgs, ... }:
    {
      checks.skill-adapters =
        pkgs.runCommand "skill-adapters-tests"
          {
            nativeBuildInputs = [ pkgs.python3 ];
          }
          ''
            mkdir -p repo/scripts repo/.claude repo/.agents
            cp ${../../scripts/skill-adapters.py} repo/scripts/skill-adapters.py
            cp ${../../scripts/skill-adapters-test.py} repo/scripts/skill-adapters-test.py
            cp -r ${../../skills} repo/skills
            cp -r ${../../.claude/skills} repo/.claude/skills
            cp -rP ${../../.agents/skills} repo/.agents/skills
            chmod -R u+w repo
            python3 repo/scripts/skill-adapters-test.py "$PWD/repo"
            python3 repo/scripts/skill-adapters.py "$PWD/repo"
            touch "$out"
          '';
    };
}
