# Generated reference for the public `my*` option surfaces (#1026).
#
# `packages.<system>.options-reference` renders docs/reference/options.md from
# the option *declarations* (`options`, never `config`) of three fixtures, each
# classified by its own guard:
#   - tests-server: the server configuration that imports every shared
#     surface, plus the modules the server profiles omit (llama-cpp,
#     llm-metrics, bambuddy), re-evaluated with a placeholder hostSpec and a
#     stub `nix-secrets` input, so no private value can reach a default and
#     generation needs no access to the private secrets flake;
#   - home-manager: a stub user with only the `vibes` module (which imports
#     `pi`), for `myPi` and `myVibes`;
#   - nix-darwin: a stub aarch64-darwin system with only the Darwin
#     `llama-cpp` module, for the Darwin-only `myLlamaCpp` options. Reading
#     options needs no Darwin build or host, so it evaluates on Linux CI.
# Only declarations, descriptions and declared defaults are read. Nothing is built for a host, no secret is
# decrypted and no host is contacted: an options walk forces no service
# package, and a default that depends on host settings is rendered from its
# `defaultText`. The renderer refuses input or output containing an email
# address, a store path, a private or tailnet address, or a name under one of
# the fleet's real domains, so a declaration that forgets `defaultText` or
# uses a real example fails here instead of being published.
#
# `task docs:options` regenerates the committed file; `checks.options-reference`
# fails when it is stale and runs the renderer's tests.
{
  inputs,
  hostSpecs,
  lib,
  ...
}:
let
  fixtureName = "tests-server";
  # Placeholders for every hostSpec field that names a person, a contact, a
  # domain or the secrets checkout. The rest (UIDs, environment, flags) is
  # public schema data.
  fixtureSpec = hostSpecs.${fixtureName} // {
    hostName = "fixture-server";
    serverDomain = "fixture.example";
    serverLanIp = "192.0.2.10";
    email = { };
    userFullName = "Fixture User";
    gh_user = "fixture";
    sopsFile = "/nix-secrets-fixture/sops/fixture-server.yaml";
  };
  fixtureInputs = inputs // {
    nix-secrets.outPath = "/nix-secrets-fixture";
  };
  fixture = inputs.self.nixosConfigurations.${fixtureName}.extendModules {
    # Surfaces the server profiles do not import: only their declarations are
    # read, and each module is inert until enabled, so no package is forced.
    modules = [
      inputs.self.modules.nixos.llama-cpp
      inputs.self.modules.nixos.llm-metrics
      inputs.self.modules.nixos.bambuddy
    ];
    specialArgs = {
      hostSpec = fixtureSpec;
      inputs = fixtureInputs;
    };
  };
  # Stub home-manager user: `vibes` imports `pi`, so one module covers both.
  # No `osConfig`, so vibes takes its no-sops path and never reads nix-secrets.
  homeFixture = inputs.home-manager.lib.homeManagerConfiguration {
    pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
    extraSpecialArgs = {
      hostSpec = fixtureSpec // {
        isDarwin = false;
      };
      inputs = fixtureInputs;
    };
    modules = [
      inputs.self.modules.homeManager.vibes
      {
        home = {
          username = "fixture";
          homeDirectory = "/home/fixture";
          stateVersion = "23.05";
        };
      }
    ];
  };

  # Stub nix-darwin system. The placeholder primary user gives the data
  # directory default (derived from the user's home) a path to render.
  darwinFixture = inputs.nix-darwin.lib.darwinSystem {
    modules = [
      inputs.self.modules.darwin.llama-cpp
      {
        nixpkgs.hostPlatform = "aarch64-darwin";
        system = {
          stateVersion = 6;
          primaryUser = "fixture";
        };
        users.users.fixture.home = "/Users/fixture";
      }
    ];
  };

  # Every top-level `my*` option a fixture declares must be in exactly one of
  # that fixture's groups, so a new surface cannot silently miss the reference.
  serverGroups = [
    {
      title = "Container plumbing";
      roots = [
        "myContainerApp"
        "myPodmanPrune"
      ];
      intro = "Per-app Podman state directories, port binding and runtime identity (`modules/system/oci-containers.nix`).";
    }
    {
      title = "Service endpoints";
      roots = [ "myServiceEndpoints" ];
      intro = "The published URL + readiness-unit contract cross-module consumers use instead of reading another module's `services.*`.";
    }
    {
      title = "State, backup and recovery";
      roots = [
        "myAppState"
        "myAppStateAudit"
        "mySqliteQuiesce"
        "myRecovery"
      ];
      intro = "One declaration per piece of state, rendered into preservation, restic paths, SQLite staging and the recovery manifest; see [app-state.md](../agents/app-state.md) and the [backup runbook](../runbooks/backup-restore.md).";
    }
    {
      title = "Credentials and databases";
      roots = [
        "myRuntimeCredentials"
        "myPostgresApp"
      ];
      intro = "App-generated API keys read at boot, and Postgres roles with sops-managed passwords.";
    }
    {
      title = "Single sign-on";
      roots = [ "myAuthentik" ];
      intro = "OIDC and forward-auth registrations hosted beside the IDP; see the [Authentik runbook](../runbooks/authentik-sso.md) and [authentik.md](../agents/authentik.md).";
    }
    {
      title = "Routing and dashboard";
      roots = [
        "myCaddy"
        "myHomepage"
      ];
      intro = "Reverse-proxy routes on the wildcard vhost and homepage tiles.";
    }
    {
      title = "Observability";
      roots = [ "myObservability" ];
      intro = "Alert rules, monitored units and exporter drop directories that apps contribute to the platform.";
    }
    {
      title = "Local LLM inference";
      roots = [
        "myLlamaCpp"
        "myLlmMetrics"
      ];
      intro = "The llama.cpp router a host serves and the metrics endpoints a host publishes for routers; procedures are in the [local LLM runbook](../runbooks/local-llm.md).";
    }
    {
      title = "Messaging";
      roots = [ "myMosquitto" ];
      intro = "MQTT broker users and ACLs.";
    }
    {
      title = "App-owned options";
      roots = [
        "myBambuddy"
        "myOmnigent"
        "myValheim"
      ];
      intro = "Options an individual app exposes for host wiring.";
    }
  ];

  homeGroups = [
    {
      title = "Coding agents (home-manager)";
      roots = [
        "myPi"
        "myVibes"
      ];
      intro = "Home-manager options, set under a user's `home-manager.users.<name>` (or a standalone home configuration); evaluated here in a stub home-manager configuration with only the `vibes` module (`modules/programs/pi.nix`, `modules/programs/vibes.nix`).";
    }
  ];

  darwinGroups = [
    {
      title = "Local LLM inference (nix-darwin)";
      roots = [ "myLlamaCpp" ];
      # The shared `myLlamaCpp` options are already listed under "Local LLM
      # inference"; only what the Darwin module itself declares is added. It is
      # attributed to the file that registers the module, which imports
      # `_llama-cpp/darwin.nix`, so that is the declaring file to match.
      onlyDeclaredIn = "modules/system/llama-cpp.nix";
      intro = "Options the nix-darwin side of `myLlamaCpp` adds to the shared ones above (`modules/system/_llama-cpp/darwin.nix`, registered by `modules/system/llama-cpp.nix`); evaluated here in a stub `aarch64-darwin` system with only that module.";
    }
  ];

  fixtures = [
    {
      name = fixtureName;
      inherit (fixture) options;
      groups = serverGroups;
    }
    {
      name = "home-manager";
      inherit (homeFixture) options;
      groups = homeGroups;
    }
    {
      name = "nix-darwin";
      inherit (darwinFixture) options;
      groups = darwinGroups;
    }
  ];

  # Fail closed per fixture: unclassified, vanished or doubly classified roots.
  problems = lib.concatMap (
    f:
    let
      declared = lib.filter (lib.hasPrefix "my") (lib.attrNames f.options);
      grouped = lib.concatMap (g: g.roots) f.groups;
      ungrouped = lib.subtractLists grouped declared;
      missing = lib.subtractLists declared grouped;
      duplicated = lib.unique (lib.filter (r: lib.count (x: x == r) grouped > 1) grouped);
    in
    lib.optional (ungrouped != [ ] || missing != [ ] || duplicated != [ ])
      "${f.name} (ungrouped: ${toString ungrouped}; no longer declared: ${toString missing}; in more than one group: ${toString duplicated})"
  ) fixtures;

  selfPrefix = "${toString inputs.self}/";
  declaration =
    d:
    lib.removePrefix selfPrefix (
      builtins.unsafeDiscardStringContext (lib.head (lib.splitString ", via option" d))
    );

  # A default that cannot be evaluated without a host is marked, not guessed.
  # So is a package, whose rendering (`<derivation name-version>`, or a store
  # path once serialised) would churn with every version bump.
  renderable =
    v:
    let
      r = builtins.tryEval (builtins.deepSeq v v);
      isPackage = x: lib.isDerivation x || lib.hasPrefix "<derivation" (x.text or "");
    in
    if r.success && !(isPackage r.value) then r.value else { _type = "unrenderable"; };

  docOption = d: {
    inherit (d) name type readOnly;
    description = d.description or null;
    default = if d ? default then renderable d.default else null;
    example = if d ? example then renderable d.example else null;
    declarations = map declaration d.declarations;
  };

  public = d: (d.visible == true || d.visible == "shallow") && !d.internal;

  # Registrable domains (last two labels) of every host's real serverDomain.
  # Public in this flake, but a resolved name under them is machine-specific.
  realDomains = lib.unique (
    map (d: lib.concatStringsSep "." (lib.takeEnd 2 (lib.splitString "." d))) (
      lib.filter (d: d != null) (lib.mapAttrsToList (_: s: s.serverDomain) hostSpecs)
    )
  );

  spec = {
    fixture = fixtureName;
    groups = lib.concatMap (
      f:
      map (
        g:
        removeAttrs g [ "onlyDeclaredIn" ]
        // {
          options = lib.filter (
            o: g.onlyDeclaredIn or null == null || lib.elem g.onlyDeclaredIn o.declarations
          ) (map docOption (lib.filter public (lib.optionAttrSetToDocList (lib.getAttrs g.roots f.options))));
        }
      ) f.groups
    ) fixtures;
    # Names under these domains must not appear; checked by the renderer.
    forbiddenDomains = realDomains;
  };
in
{
  perSystem =
    { pkgs, ... }:
    let
      json =
        if problems != [ ] then
          throw "options-reference: classify every top-level my* option of each fixture in exactly one of its groups in modules/flake/options-reference.nix: ${lib.concatStringsSep "; " problems}"
        else
          pkgs.writeText "options-reference.json" (builtins.toJSON spec);
      reference = pkgs.runCommand "options-reference.md" {
        nativeBuildInputs = [ pkgs.python3 ];
      } ''python3 ${../../scripts/options-reference.py} ${json} > "$out"'';
    in
    {
      packages.options-reference = reference;

      checks.options-reference =
        pkgs.runCommand "options-reference-current" { nativeBuildInputs = [ pkgs.python3 ]; }
          ''
            python3 ${../../scripts/options-reference-test.py} ${../../scripts/options-reference.py}
            if ! diff -u ${../../docs/reference/options.md} ${reference}; then
              echo "docs/reference/options.md is stale: run 'task docs:options' and commit the result" >&2
              exit 1
            fi
            touch "$out"
          '';
    };
}
