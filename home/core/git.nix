{
  pkgs,
  # lib,
  config,
  hostSpec,
  # inputs,
  ...
}:
let
  publicGitEmail = hostSpec.email.gitHub;
  workGitEmail = hostSpec.email.work;
  workGitConfig = "${config.home.homeDirectory}/.config/git/gitconfig.work";
in
{
  programs.git = {
    enable = true;
    package = pkgs.gitFull;
    settings = {
      user.name = hostSpec.gh_user;
      user.email = "${publicGitEmail}";
      init.defaultBranch = "main";
      pull.ff = "only";
      push.default = "current";
      rebase.autostash = "true";
      core.editor = "nvim";
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
  };
  home.file."${workGitConfig}".text = ''
    [user]
      name = "${hostSpec.userFullName}"
      email = "${workGitEmail}"
  '';
}
