{
  pkgs,
  # lib,
  config,
  # inputs,
  ...
}:
let
  publicGitEmail = config.hostSpec.email.gitHub;
  workGitEmail = config.hostSpec.email.work;
  # privateGitConfig = "${config.home.homeDirectory}/.config/git/gitconfig.private";
  workGitConfig = "${config.home.homeDirectory}/.config/git/gitconfig.work";
in
{
  programs.git = {
    enable = true;
    package = pkgs.gitAndTools.gitFull;
    userName = config.hostSpec.handle;
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
      name = "${config.hostSpec.userFullName}"
      email = "${workGitEmail}"
  '';
}
