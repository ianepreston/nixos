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
      # buf # added by default, don't think I need it
      # clang provides both LSP Server for C/C++ and a C compiler for treesitter parsers
      clang
      # lldb # C debugger I don't think I need
      lua-language-server
      stylua
      # gopls
      # gomodifytags
      lua51Packages.lua
      lua51Packages.luv
      lua51Packages.luarocks-nix
      lua51Packages.jsregexp
      statix
      nixpkgs-fmt
      # go-tools
      # rust-analyzer
      dockerfile-language-server-nodejs
      emmet-language-server
      vscode-langservers-extracted
      nixd
      nil
      prettierd
      typescript-language-server
      eslint
      python312Packages.debugpy
      # delve # go debugger
      taplo
      yaml-language-server
      yamlfmt
      ruff
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
    config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/nixos/home/core/neovim";

  # Tools available during activation
  home.extraActivationPath = with pkgs; [
    git
    gnumake
    gcc
    config.programs.neovim.finalPackage
    # The package above is preferred, but if you can't make it work, use this instead:
    # neovim
  ];

  # Activation script to set up Neovim plugins
  home.activation.updateNeovimState = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    args=""
    if [[ -z "''${VERBOSE+x}" ]]; then
      args="--quiet"
    fi
    run $args nvim --headless '+Lazy! restore' +qa
  '';
}
