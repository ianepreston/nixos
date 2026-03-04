{ config, hostSpec, ... }:
let
  workGitEmail = hostSpec.email.work;
  workGitConfig = "${config.home.homeDirectory}/.config/git/gitconfig.work";
in
{
  imports = [
    ../core/default.nix
    ../darwin
  ];
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
      "hasconfig:remote.*.url:https://github.com/databricks-field-eng/**".path = workGitConfig;
      "hasconfig:remote.*.url:https://github.com/databricks-eng/**".path = workGitConfig;
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
  '';
}
