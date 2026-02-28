{ config, hostSpec, ... }:
let
  workGitEmail = hostSpec.email.work;
  workGitConfig = "${config.home.homeDirectory}/.config/git/gitconfig.work";
in
{
  imports = [
    ../core/default.nix
  ];
  xdg.configFile."ghostty/config" = {
    text = ''
      theme = Catppuccin Latte
      font-family = FiraCode Nerd Font Mono
      clipboard-read = allow
      clipboard-write = allow
      font-size = 11
    '';
  };
  programs.git.settings = {
    includeIf = {
      "hasconfig:remote.*.url:git@github.com-emu:databricks-field-eng/**".path = workGitConfig;
      "hasconfig:remote.*.url:git@github.com-emu:databricks-eng/**".path = workGitConfig;
    };
    url = {
      "git@github.com-emu:databricks-eng" = {
        insteadOf = "git@github.com:databricks-eng";
      };
      "git@github.com-emu:databricks-field-eng" = {
        insteadOf = "git@github.com:databricks-field-eng";
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
}
