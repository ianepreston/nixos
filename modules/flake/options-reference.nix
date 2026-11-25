# Generated reference for the public `my*` option surfaces (#1026).
#
# `packages.<system>.options-reference` renders docs/reference/options.md from
# the option *declarations* (`options`, never `config`) of a fixture: the
# tests-server module set (the server configuration that imports every shared
# surface) re-evaluated with a placeholder hostSpec and a stub `nix-secrets`
# input, so no private value can reach a default and generation needs no
# access to the private secrets flake. Only declarations, descriptions and
# declared defaults are read. Nothing is built for a host, no secret is
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
    specialArgs = {
      hostSpec = fixtureSpec;
      inputs = fixtureInputs;
    };
  };
  inherit (fixture) options;

  # Every top-level `my*` option the fixture declares must be in exactly one
  # group, so a new surface cannot silently miss the reference.
  groups = [
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
      title = "Messaging";
      roots = [ "myMosquitto" ];
      intro = "MQTT broker users and ACLs.";
    }
    {
      title = "App-owned options";
      roots = [
        "myOmnigent"
        "myValheim"
      ];
      intro = "Options an individual app exposes for host wiring.";
    }
  ];

  declared = lib.filter (lib.hasPrefix "my") (lib.attrNames options);
  grouped = lib.concatMap (g: g.roots) groups;
  ungrouped = lib.subtractLists grouped declared;
  missing = lib.subtractLists declared grouped;
  duplicated = lib.unique (lib.filter (r: lib.count (x: x == r) grouped > 1) grouped);

  selfPrefix = "${toString inputs.self}/";
  declaration =
    d:
    lib.removePrefix selfPrefix (
      builtins.unsafeDiscardStringContext (lib.head (lib.splitString ", via option" d))
    );

  # A default that cannot be evaluated without a host is marked, not guessed.
  renderable =
    v:
    let
      r = builtins.tryEval (builtins.deepSeq v v);
    in
    if r.success then r.value else { _type = "unrenderable"; };

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
    groups = map (
      g:
      g
      // {
        options = map docOption (
          lib.filter public (lib.optionAttrSetToDocList (lib.getAttrs g.roots options))
        );
      }
    ) groups;
    # Names under these domains must not appear; checked by the renderer.
    forbiddenDomains = realDomains;
  };
in
{
  perSystem =
    { pkgs, ... }:
    let
      json =
        if ungrouped != [ ] || missing != [ ] || duplicated != [ ] then
          throw "options-reference: classify every top-level my* option of ${fixtureName} in exactly one group in modules/flake/options-reference.nix (ungrouped: ${toString ungrouped}; no longer declared: ${toString missing}; in more than one group: ${toString duplicated})"
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
