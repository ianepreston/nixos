{
  pkgs,
  hostSpec,
  ...
}:
let
  publicGitEmail = hostSpec.email.gitHub;
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
    };
  };
}
