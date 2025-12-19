{
  config,
  pkgs,
  lib,
  ...
}:
{
  programs.neovim = {
    enable = true;

    # Often required; don't worry as they are isolated in Neovim environment
    withPython3 = true;
    withNodeJs = true;

    # Packages available within Neovim during runtime. Put your LSP Servers, formatters, linters, etc.
    extraPackages = with pkgs; [
      bash-language-server
      codespell
      clang
      lua-language-server
      stylua
      lua51Packages.lua
      lua51Packages.luv
      lua51Packages.luarocks-nix
      lua51Packages.jsregexp
      statix
      nixpkgs-fmt
      dockerfile-language-server
      hadolint # docker linter
      emmet-language-server
      vscode-langservers-extracted
      nixd
      nil
      prettierd
      typescript-language-server
      eslint
      python3Packages.debugpy
      shellcheck
      taplo
      yaml-language-server
      yamlfmt
      yamllint
      ruff
      shfmt
      isort
      terraform-ls
      tflint
      opentofu
      basedpyright
      tree-sitter
    ];
  };

  # Symlink your Neovim configuration (or delete the line to manage .config/nvim directly)
  xdg.configFile."nvim".source =
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/src/nixos/home/core/neovim";

  # Tools available during activation
  home.extraActivationPath = with pkgs; [
    git
    gnumake
    gcc
    config.programs.neovim.finalPackage
    # The package above is preferred, but if you can't make it work, use this instead:
    # neovim
  ];

  # Add a dummy file to satisfy the module but avoid using it
  # Activation script to set up Neovim plugins
  home.activation.updateNeovimState = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    # if [ ! -e "$HOME/.config/nvim" ]; then
    #   ln -s "$HOME/nixos/home/core/neovim" "$HOME/.config/nvim"
    # fi
    args=""
    if [[ -z "''${VERBOSE+x}" ]]; then
      args="--quiet"
    fi
    run $args nvim --headless '+Lazy! restore' +qa
  '';
}
