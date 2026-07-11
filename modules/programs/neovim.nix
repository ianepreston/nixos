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
    let
      # ---- Tree-sitter parsers + queries, vendored from nixpkgs ----------
      # The archived nvim-treesitter Lua plugin is gone; we consume nixpkgs'
      # native tree-sitter artifacts (parsers + queries) directly and put them
      # on Neovim's packpath, with no nvim-treesitter Lua runtime involved.
      #
      # Phase 1 vendors ONLY `nix`. Neovim 0.12 already ships parsers AND
      # queries for the core langs (c, lua, markdown, markdown_inline, query,
      # vim, vimdoc) and auto-activates them, so we deliberately do NOT
      # re-vendor those (re-vendoring risks ABI skew vs core). Phase 2 expands
      # this list (python, yaml, bash, json, hcl, go, rust, toml) — a one-line
      # edit here.
      tsLangs = [
        "nix"
        "python"
        "yaml"
        "bash"
        "json"
        "hcl"
        "go"
        "rust"
        "toml"
      ];

      tsPlugin = pkgs.vimPlugins.nvim-treesitter;
      tsTextobjectsSrc = pkgs.vimPlugins.nvim-treesitter-textobjects.src;

      # One package holding, per vendored lang: `parser/<lang>.so` (correctly
      # renamed by nixpkgs' to-nvim-treesitter-grammar.sh) plus its
      # neovim-adapted `queries/<lang>/*.scm` (highlights, folds, indents,
      # injections, locals) and the textobjects.scm queries. The textobjects
      # queries come straight from the nixpkgs-pinned textobjects source — we
      # take its `queries/` only, never the archived textobjects Lua runtime —
      # so query content stays in ABI lockstep with the grammars (query-content
      # decision B: everything follows the nixpkgs pin). This carries no
      # nvim-treesitter Lua runtime.
      #
      # We assemble into real directories with `cp -L` rather than symlinkJoin:
      # lndir symlinks a lang's whole `queries/<lang>` dir from the first source
      # that provides it, which would drop the textobjects.scm coming from a
      # second source. A file-level copy merges all query groups cleanly.
      nvimTreesitterVendored = pkgs.runCommandLocal "nvim-treesitter-vendored" { } ''
        mkdir -p "$out/parser"
        ${lib.concatMapStringsSep "\n" (l: ''
          cp -L ${tsPlugin.passthru.grammarPlugins.${l}}/parser/*.so "$out/parser/"
          mkdir -p "$out/queries/${l}"
          cp -L ${tsPlugin.passthru.queries.${l}}/queries/${l}/*.scm "$out/queries/${l}/"
          if [ -d "${tsTextobjectsSrc}/queries/${l}" ]; then
            cp -L "${tsTextobjectsSrc}/queries/${l}"/*.scm "$out/queries/${l}/"
          fi
        '') tsLangs}
      '';
    in
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

      # Vendored tree-sitter parsers + queries on Neovim's packpath. Neovim
      # auto-adds `pack/*/start/*` dirs, and lazy.nvim re-adds it via
      # `performance.rtp.paths` in lua/plugin-loader.lua (lazy resets the rtp,
      # so the explicit path entry is what keeps it discoverable).
      xdg.dataFile."nvim/site/pack/nix-ts/start/nvim-treesitter-vendored".source = nvimTreesitterVendored;
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
