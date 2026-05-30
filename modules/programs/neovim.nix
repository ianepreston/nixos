# Neovim - HM module
# Heavy developer setup: LSPs, formatters, linters, language runtimes.
# Lives outside `core` so server profiles can ship vanilla nvim instead.
_: {
  flake.modules.homeManager.neovim =
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
        # Default in HM 26.05 is `false`; set explicitly to silence the
        # `home.stateVersion < 26.05` migration warning.
        withRuby = true;

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
          prettier
          typescript-language-server
          eslint
          python313Packages.debugpy
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
          ty
          tree-sitter
        ];
      };

      # Symlink your Neovim configuration (or delete the line to manage .config/nvim directly).
      # As of HM 26.05, the upstream `programs.neovim` module always emits
      # `xdg.configFile."nvim/init.lua"` (even just to set
      # `vim.g.loaded_*_provider=0`). That child entry collides with this
      # whole-directory symlink in the home-manager-files build (the install
      # script checks every target stays under $HOME after realpath). Force
      # the child off so only our symlink survives.
      xdg.configFile = {
        "nvim".source =
          config.lib.file.mkOutOfStoreSymlink "${config.home.homeDirectory}/src/nixos/modules/programs/neovim";
        "nvim/init.lua".enable = lib.mkForce false;

        # Make yamlfmt not fight with yamllint
        "yamlfmt/.yamlfmt".text = ''
          formatter:
            type: basic
            include_document_start: true
        '';
      };
      # Tools available during activation
      home.extraActivationPath = with pkgs; [
        git
        gnumake
        gcc
        config.programs.neovim.finalPackage
      ];

      # Activation script to set up Neovim plugins
      home.activation.updateNeovimState = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        args=""
        if [[ -z "''${VERBOSE+x}" ]]; then
          args="--quiet"
        fi
        run $args nvim --headless '+Lazy! restore' +qa
      '';
    };
}
