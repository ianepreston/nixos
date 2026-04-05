# Pre-commit hooks via git-hooks.nix
{ inputs, ... }:
{
  imports = [ inputs.git-hooks.flakeModule ];

  perSystem = _: {
    pre-commit.settings.hooks = {
      # Nix formatting
      nixfmt-rfc-style.enable = true;

      # Nix linting
      statix.enable = true; # Catches anti-patterns, unused bindings, etc.
      deadnix.enable = true; # Finds dead/unreferenced Nix code

      # Prevent secrets from leaking
      ripsecrets.enable = true;

      # YAML/JSON validation
      check-yaml.enable = true;
      check-json.enable = true;

      # Whitespace hygiene
      trim-trailing-whitespace.enable = true;
      end-of-file-fixer.enable = true;
    };
  };
}
