# Conflict checks for the shared app registries (#1023): postgres database,
# role and secret ownership (`myPostgresApp`), Caddy host claims
# (`myCaddy.apps`) and SQLite staging destinations (`mySqliteQuiesce.apps`).
#
# Each case extends tests-server, a real server with every registry already
# populated, with synthetic contributions and compares the complete set of
# registry assertion messages with the expected ones. `baseline` proves the
# real host is clean, so a case sees only its own conflicts.
#
# The runtime check renders units whose staged names are only known once a
# glob is resolved, rewrites their fixed paths into the build directory and
# runs them against real SQLite files.
{ inputs, hostSpecs, ... }:
{
  perSystem =
    {
      pkgs,
      lib,
      system,
      ...
    }:
    let
      base = inputs.self.nixosConfigurations.tests-server;
      domain = hostSpecs.tests-server.serverDomain;
      extend = module: (base.extendModules { modules = [ module ]; }).config;

      prefixes = [
        "myPostgresApp:"
        "myCaddy.apps:"
        "mySqliteQuiesce."
      ];
      # `assertion` first: some modules' messages only evaluate when failing.
      failures =
        cfg:
        lib.sort lib.lessThan (
          lib.filter (m: lib.any (p: lib.hasPrefix p m) prefixes) (
            map (a: a.message) (lib.filter (a: !a.assertion) cfg.assertions)
          )
        );

      route.routeConfig = "respond 204";
      sqlite = databases: { mySqliteQuiesce.apps.fixture = { inherit databases; }; };

      # `fail`: every registry assertion message the case must produce.
      cases = {
        baseline = {
          module = { };
        };

        postgres-normalized-names-collide = {
          module.myPostgresApp = {
            foo-bar = { };
            foo_bar = { };
          };
          fail = [
            "myPostgresApp: database and role `foo_bar` is claimed by myPostgresApp.foo-bar, myPostgresApp.foo_bar; each app needs its own dbName (the default replaces hyphens in the attribute name with underscores)."
          ];
        };

        postgres-explicit-name-collides-with-app = {
          module.myPostgresApp.extra.dbName = "tandoor";
          fail = [
            "myPostgresApp: database and role `tandoor` is claimed by myPostgresApp.extra, myPostgresApp.tandoor; each app needs its own dbName (the default replaces hyphens in the attribute name with underscores)."
          ];
        };

        postgres-shared-secret = {
          module.myPostgresApp = {
            first.secretName = "shared/db_password";
            second.secretName = "shared/db_password";
            third.secretName = "shared/db_password";
          };
          fail = [
            "myPostgresApp: sops secret `shared/db_password` is claimed by myPostgresApp.first, myPostgresApp.second, myPostgresApp.third; each role needs its own secretName."
          ];
        };

        postgres-distinct-passes = {
          module.myPostgresApp = {
            foo-bar = { };
            foo_bar.dbName = "foo_bar_legacy";
          };
        };

        caddy-duplicate-host = {
          module.myCaddy.apps = {
            alpha = route // {
              host = "shared.${domain}";
            };
            beta = route // {
              host = "shared.${domain}";
            };
          };
          fail = [
            "myCaddy.apps: host `shared.${domain}` is claimed by myCaddy.apps.alpha, myCaddy.apps.beta; only one route per host can be served."
          ];
        };

        caddy-default-host-collides-case-insensitively = {
          module.myCaddy.apps = {
            delta = route;
            epsilon = route // {
              host = "Delta.${domain}";
            };
          };
          fail = [
            "myCaddy.apps: host `delta.${domain}` is claimed by myCaddy.apps.delta, myCaddy.apps.epsilon; only one route per host can be served."
          ];
        };

        caddy-multi-host-matcher-collides = {
          module.myCaddy.apps = {
            zeta = route // {
              host = "zeta.${domain}  eta.${domain}";
            };
            eta = route;
          };
          fail = [
            "myCaddy.apps: host `eta.${domain}` is claimed by myCaddy.apps.eta, myCaddy.apps.zeta; only one route per host can be served."
          ];
        };

        caddy-distinct-hosts-pass = {
          module.myCaddy.apps = {
            alpha = route // {
              host = "alpha.${domain}";
            };
            beta = route // {
              host = "beta.${domain} beta.${domain}";
            };
          };
        };

        sqlite-literal-basename-collision = {
          module = sqlite [
            "/srv/one/data.db"
            "/srv/two/data.db"
            "/srv/two/other.db"
            "/srv/three/data.db"
          ];
          fail = [
            "mySqliteQuiesce.apps.fixture.databases: `/srv/one/data.db`, `/srv/two/data.db`, `/srv/three/data.db` all stage to /var/backup/sqlite/fixture/data.db; each database needs a distinct basename."
          ];
        };

        sqlite-static-glob-name-collision = {
          module = sqlite [
            "/srv/profiles/*/app.db"
            "/srv/app.db"
          ];
          fail = [
            "mySqliteQuiesce.apps.fixture.databases: `/srv/profiles/*/app.db`, `/srv/app.db` all stage to /var/backup/sqlite/fixture/app.db; each database needs a distinct basename."
          ];
        };

        # Runtime-named entries are left to the unit (see the runtime check).
        sqlite-distinct-passes = {
          module = sqlite [
            "/srv/one.db"
            "/srv/profiles/*/two.db"
            "/srv/dynamic/*.db"
            "/srv/more/*.db"
          ];
        };
      };

      problems = lib.concatLists (
        lib.mapAttrsToList (
          name: c:
          let
            got = failures (extend c.module);
            want = lib.sort lib.lessThan (c.fail or [ ]);
            show = ls: lib.concatMapStrings (l: "\n    ${l}") ls;
          in
          lib.optional (got != want) ''
            ${name}: registry assertion messages differ
              want:${show want}
              got:${show got}''
        ) cases
      );

      # Runtime cases. Paths under /quiesce-fixture and the staging root are
      # rewritten into the build directory before the unit runs. `setup`
      # creates the source databases (each recording its unrewritten path)
      # and any pre-existing staged file; `stderr` and `staged` are the complete
      # expected error output and staging directory listing afterwards.
      fx = "/quiesce-fixture";
      runtimeCases = {
        distinct-names-stage-all = {
          databases = [
            "${fx}/lit/one.db"
            "${fx}/gl/*.db"
            "${fx}/absent/three.db"
          ];
          setup = [
            "lit/one.db"
            "gl/two.db"
          ];
          status = 0;
          staged = [
            "one.db=${fx}/lit/one.db"
            "two.db=${fx}/gl/two.db"
          ];
        };

        glob-collision-writes-nothing = {
          databases = [
            "${fx}/a/*.db"
            "${fx}/b/*.db"
          ];
          setup = [
            "a/x.db"
            "b/x.db"
          ];
          previous = "x.db";
          status = 1;
          stderr = "mySqliteQuiesce: ${fx}/a/x.db and ${fx}/b/x.db both stage to /var/backup/sqlite/rt-glob-collision-writes-nothing/x.db; no staged copy was written";
          staged = [ "x.db=previous" ];
        };

        absent-literal-reserves-name = {
          databases = [
            "${fx}/c/x.db"
            "${fx}/d/*.db"
          ];
          setup = [ "d/x.db" ];
          status = 1;
          stderr = "mySqliteQuiesce: ${fx}/c/x.db and ${fx}/d/x.db both stage to /var/backup/sqlite/rt-absent-literal-reserves-name/x.db; no staged copy was written";
          staged = [ ];
        };

        multi-match-glob-still-fails = {
          databases = [
            "${fx}/e/first.db"
            "${fx}/m/*.db"
          ];
          setup = [
            "e/first.db"
            "m/one.db"
            "m/two.db"
          ];
          status = 1;
          stderr = "${fx}/m/*.db matched 2 files, expected 1";
          staged = [ ];
        };
      };

      runtimeConfig = extend {
        mySqliteQuiesce.apps = lib.mapAttrs' (
          name: c: lib.nameValuePair "rt-${name}" { inherit (c) databases; }
        ) runtimeCases;
      };

      runtimeCase =
        name: c:
        let
          unit = "rt-${name}";
          script =
            pkgs.writeText "${unit}-script"
              runtimeConfig.systemd.services."${unit}-sqlite-backup".script;
          expected = pkgs.writeText "${unit}-expected" (
            lib.concatMapStrings (l: "${l}\n") (lib.sort lib.lessThan c.staged)
          );
          expectedErr = pkgs.writeText "${unit}-stderr" (lib.optionalString (c ? stderr) "${c.stderr}\n");
        in
        ''
          (
            name=${lib.escapeShellArg name}
            dst="$ST/${unit}"
            mkdir -p "$dst"
            ${lib.concatMapStrings (f: ''
              mkdir -p "$FX/$(dirname ${f})"
              sqlite3 "$FX/${f}" "create table origin(path text); insert into origin values ('${fx}/${f}')"
            '') c.setup}
            ${lib.optionalString (c ? previous) ''echo previous > "$dst/${c.previous}"''}
            rewrite < ${script} > "$name.sh"
            if bash "$name.sh" 2> "$name.err"; then rc=0; else rc=$?; fi
            [ "$rc" = ${toString c.status} ] || fail "$name: exit $rc, want ${toString c.status}"
            rewrite < ${expectedErr} | diff -u - "$name.err" > "$name.diff" || fail "$name: stderr differs" "$name.diff"
            for f in "$dst"/*; do
              [ -e "$f" ] || continue
              if [ "$(head -c 15 "$f")" = "SQLite format 3" ]; then
                echo "$(basename "$f")=$(sqlite3 "$f" 'select path from origin')"
              else
                echo "$(basename "$f")=$(cat "$f")"
              fi
            done | sort > "$name.staged"
            diff -u ${expected} "$name.staged" > "$name.sdiff" || fail "$name: staged files differ" "$name.sdiff"
          )
        '';
    in
    {
      # Evaluates a full host configuration, so only once, for the system
      # the servers run.
      checks = lib.optionalAttrs (system == "x86_64-linux") {
        registry-conflicts =
          pkgs.runCommand "registry-conflicts"
            {
              passAsFile = [ "report" ];
              report = lib.concatStringsSep "\n\n" problems;
            }
            ''
              ${
                if problems == [ ] then
                  ''echo "${toString (lib.length (lib.attrNames cases))} registry compositions passed"''
                else
                  ''cat "$reportPath"; exit 1''
              }
              touch "$out"
            '';

        registry-conflicts-sqlite-runtime =
          pkgs.runCommand "registry-conflicts-sqlite-runtime" { nativeBuildInputs = [ pkgs.sqlite ]; }
            ''
              FX="$PWD/fx"
              ST="$PWD/staging"
              rewrite() { sed -e "s|${fx}|$FX|g" -e "s|/var/backup/sqlite|$ST|g"; }
              : > failures
              fail() {
                echo "$1" >> failures
                if [ -n "''${2:-}" ]; then cat "$2" >> failures; fi
              }
              ${lib.concatStrings (lib.mapAttrsToList runtimeCase runtimeCases)}
              if [ -s failures ]; then
                cat failures
                exit 1
              fi
              echo "${toString (lib.length (lib.attrNames runtimeCases))} runtime staging cases passed"
              touch "$out"
            '';
      };
    };
}
