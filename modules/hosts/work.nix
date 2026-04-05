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
      ./_work-homebrew.nix
      ./_work-system-settings.nix
      ./_work-yubikey.nix
      {
        system.primaryUser = hostSpec.username;

        home-manager.sharedModules = [
          inputs.self.modules.homeManager.hammerspoon

          # Work-specific HM config
          (_: {
            home.file."Library/Application Support/com.mitchellh.ghostty/config" = {
              text = ''
                theme = Catppuccin Latte
                font-family = FiraCode Nerd Font Mono
                clipboard-read = allow
                clipboard-write = allow
                font-size = 14
              '';
            };
            programs.git.settings = {
              includeIf = {
                "hasconfig:remote.*.url:git@github.com-emu:databricks-field-eng/**".path = workGitConfig;
                "hasconfig:remote.*.url:git@github.com-emu:databricks-eng/**".path = workGitConfig;
                "hasconfig:remote.*.url:git@github.com-emu:ian-preston_data/**".path = workGitConfig;
                "hasconfig:remote.*.url:https://github.com/databricks-field-eng/**".path = workGitConfig;
                "hasconfig:remote.*.url:https://github.com/databricks-eng/**".path = workGitConfig;
                "hasconfig:remote.*.url:https://github.com/ian-preston_data/**".path = workGitConfig;
              };
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
            home.file."${workGitConfig}".text = ''
              [user]
                name = "ian-preston_data"
                email = "${workGitEmail}"
              [github]
                name = "ian-preston_data"
            '';
            programs.zsh.initContent = ''
              alias llm="dbexec repo run llm"
              alias isaac="dbexec repo run isaac"
              export I_DANGEROUSLY_OPT_IN_TO_UNSUPPORTED_ALPHA_TOOLS=true
              export MCP_PRIVACY_SUMMARIZATION_ENABLED=true
              export JAVA_HOME="/opt/homebrew/opt/openjdk@17"
              export PATH="$JAVA_HOME/bin:$PATH"
            '';
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
