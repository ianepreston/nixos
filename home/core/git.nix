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
  # privateGitConfig = "${config.home.homeDirectory}/.config/git/gitconfig.private";
  workGitConfig = "${config.home.homeDirectory}/.config/git/gitconfig.work";
in
{
  programs.git = {
    enable = true;
    package = pkgs.gitAndTools.gitFull;
    userName = hostSpec.gh_user;
    userEmail = "${publicGitEmail}";
    extraConfig = {
      init.defaultBranch = "main";
      pull.ff = "only";
      push.default = "current";
      rebase.autostash = "true";
      core.editor = "nvim";
      includeIf."hasconfig:remote.*.url:git@ssh.dev.azure.com*/**".path = workGitConfig;
    };
  };
  # home.file."${privateGitConfig}".text = ''
  #   [user]
  #     name = "${config.hostSpec.handle}"
  #     email = ${publicGitEmail}
  # '';
  home.file."${workGitConfig}".text = ''
    [user]
      name = "${hostSpec.userFullName}"
      email = "${workGitEmail}"
  '';
}
