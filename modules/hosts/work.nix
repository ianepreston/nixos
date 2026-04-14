# Work - Darwin work machine
{
  inputs,
  hostSpecs,
  ...
}:
let
  hostSpec = hostSpecs.work;
  workGitEmail = hostSpec.email.work;
  workGitConfig = "${hostSpec.home}/.config/git/gitconfig.work";
in
{
  flake.darwinConfigurations.work = inputs.nix-darwin.lib.darwinSystem {
    specialArgs = {
      inherit inputs;
      inherit (inputs.nixpkgs-darwin) lib;
      inherit hostSpec;
    };
    modules = [
      inputs.self.modules.darwin.base
      inputs.self.modules.darwin.desktop
      inputs.self.modules.darwin.homebrew
      inputs.self.modules.darwin.yubikey
      ./_work-homebrew.nix
      {
        system.primaryUser = hostSpec.username;

        home-manager.sharedModules = [
          inputs.self.modules.homeManager.hammerspoon
          inputs.self.modules.homeManager.ghostty

          # Work-specific HM config
          (_: {
            programs = {
              git = {
                signing = {
                  key = "${hostSpec.home}/.ssh/github_emu_key.pub";
                  signByDefault = true;
                  format = "ssh";
                };
                settings = {
                  core.hooksPath = "${hostSpec.home}/.databricks/githooks";
                  gpg.ssh.allowedSignersFile = "${hostSpec.home}/.ssh/allowed_signers";
                  url = {
                    "git@github.com-emu:databricks-eng/" = {
                      insteadOf = [
                        "git@github.com:databricks-eng/"
                        "https://github.com/databricks-eng/"
                      ];
                    };
                    "git@github.com-emu:databricks-field-eng/" = {
                      insteadOf = [
                        "git@github.com:databricks-field-eng/"
                        "https://github.com/databricks-field-eng/"
                      ];
                    };
                    "git@github.com-emu:ian-preston_data/" = {
                      insteadOf = [
                        "git@github.com:ian-preston_data/"
                        "https://github.com/ian-preston_data/"
                      ];
                    };
                    "git@github.com-emu:" = {
                      insteadOf = [
                        "org-145372899@github.com:"
                        "org-140212977@github.com:"
                      ];
                    };
                    "git@github.com:" = {
                      insteadOf = "https://github.com/";
                    };
                  };
                };
                includes =
                  let
                    workConditions = [
                      "hasconfig:remote.*.url:git@github.com-emu:databricks-field-eng/**"
                      "hasconfig:remote.*.url:git@github.com-emu:databricks-eng/**"
                      "hasconfig:remote.*.url:git@github.com-emu:ian-preston_data/**"
                      "hasconfig:remote.*.url:https://github.com/databricks-field-eng/**"
                      "hasconfig:remote.*.url:https://github.com/databricks-eng/**"
                      "hasconfig:remote.*.url:https://github.com/ian-preston_data/**"
                      # Match repos cloned with org-number URLs (before insteadOf rewrite)
                      # Bare ** doesn't cross /; use */** so the glob matches org/repo
                      "hasconfig:remote.*.url:org-140212977@github.com:*/**"
                      "hasconfig:remote.*.url:org-145372899@github.com:*/**"
                    ];
                  in
                  map (condition: {
                    inherit condition;
                    path = workGitConfig;
                  }) workConditions;
              };
              zsh.initContent = ''
                alias llm="dbexec repo run llm"
                alias isaac="dbexec repo run isaac"
                export I_DANGEROUSLY_OPT_IN_TO_UNSUPPORTED_ALPHA_TOOLS=true
                export MCP_PRIVACY_SUMMARIZATION_ENABLED=true
                export CLAUDE_NVIM_CMD="vibe agent"
                export JAVA_HOME="/opt/homebrew/opt/openjdk@17"
                export PATH="$JAVA_HOME/bin:$PATH"
              '';
            };
            home.file = {
              "${workGitConfig}".text = ''
                [user]
                  name = "ian-preston_data"
                  email = "${workGitEmail}"
                [github]
                  name = "ian-preston_data"
              '';
              ".config/uv/uv.toml".text = ''
                [[index]]
                url = "https://pypi-proxy.dev.databricks.com/simple"
              '';
            };
          })
        ];

        networking.hostName = inputs.nix-secrets.workvm_hostname;
        nixpkgs.hostPlatform = "aarch64-darwin";
        nix.enable = false;

        system.stateVersion = 6;
      }
    ];
  };
}
