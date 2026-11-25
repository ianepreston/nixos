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
        "myPostgresApp"
        "myCaddy.apps"
        "mySqliteQuiesce"
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
      hosts = host: route // { inherit host; };
      # The complete name-collision message for postgres apps claiming `id`.
      pgClaim =
        id: claims:
        "myPostgresApp: database and role `${id}` is claimed by ${
          lib.concatMapStringsSep ", " (c: "myPostgresApp.${c.app} (dbName `${c.db}`)") claims
        }; PostgreSQL folds unquoted names to lower case and truncates them to 63 bytes, so each app needs a dbName that stays distinct after that (the default replaces hyphens in the attribute name with underscores).";
      a63 = lib.strings.replicate 63 "a";
      caddyOverlap =
        a: an: b: bn:
        "myCaddy.apps: host `${a}` (myCaddy.apps.${an}) overlaps host `${b}` (myCaddy.apps.${bn}); only one route per host can be served.";
      caddyUncheckable =
        n: token:
        "myCaddy.apps.${n}.host: `${token}` cannot be checked for overlapping claims; write a plain ASCII hostname (Punycode for internationalized names) with no port or placeholder, using `*` only as a whole label.";
      sqliteUnsafe =
        db: base:
        "mySqliteQuiesce.apps.fixture.databases: `${db}` stages as `${base}`, which sqlite's .backup cannot take unquoted; staged names may only use letters, digits and `._+@%,:=~-`.";
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
            "myPostgresApp: database and role `foo_bar` is claimed by myPostgresApp.foo-bar (dbName `foo_bar`), myPostgresApp.foo_bar (dbName `foo_bar`); PostgreSQL folds unquoted names to lower case and truncates them to 63 bytes, so each app needs a dbName that stays distinct after that (the default replaces hyphens in the attribute name with underscores)."
          ];
        };

        postgres-explicit-name-collides-with-app = {
          module.myPostgresApp.extra.dbName = "tandoor";
          fail = [
            (pgClaim "tandoor" [
              {
                app = "extra";
                db = "tandoor";
              }
              {
                app = "tandoor";
                db = "tandoor";
              }
            ])
          ];
        };

        # The rotation's unquoted ALTER USER folds case.
        postgres-case-folded-names-collide = {
          module.myPostgresApp = {
            lower.dbName = "fixture_role";
            mixed.dbName = "Fixture_Role";
          };
          fail = [
            (pgClaim "fixture_role" [
              {
                app = "lower";
                db = "fixture_role";
              }
              {
                app = "mixed";
                db = "Fixture_Role";
              }
            ])
          ];
        };

        # Identifiers are truncated to 63 bytes: names sharing exactly their
        # first 63 bytes collide, and a name differing within them does not.
        postgres-truncated-names-collide = {
          module.myPostgresApp = {
            long-one.dbName = "${a63}1";
            long-two.dbName = "${a63}2";
            exact.dbName = lib.strings.replicate 62 "a" + "b";
          };
          fail = [
            (pgClaim a63 [
              {
                app = "long-one";
                db = "${a63}1";
              }
              {
                app = "long-two";
                db = "${a63}2";
              }
            ])
          ];
        };

        postgres-unquotable-names-fail = {
          module.myPostgresApp = {
            hyphen.dbName = "bad-name";
            digit.dbName = "1st";
          };
          fail = [
            "myPostgresApp.digit.dbName: `1st` is not a plain SQL identifier (letters, digits, `_` and `$`, not starting with a digit or `$`); the password rotation passes it to ALTER USER unquoted."
            "myPostgresApp.hyphen.dbName: `bad-name` is not a plain SQL identifier (letters, digits, `_` and `$`, not starting with a digit or `$`); the password rotation passes it to ALTER USER unquoted."
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
            dollar.dbName = "with$dollar";
            exact.dbName = a63;
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

        caddy-quoted-host-collides = {
          module.myCaddy.apps = {
            alpha = hosts ''"Shared.${domain}"'';
            beta = hosts "shared.${domain}";
          };
          fail = [
            "myCaddy.apps: host `shared.${domain}` is claimed by myCaddy.apps.alpha, myCaddy.apps.beta; only one route per host can be served."
          ];
        };

        # A whole-label `*` matches any one label at its position.
        caddy-wildcard-covers-exact-host = {
          module.myCaddy.apps = {
            alpha = hosts "*.lab.${domain}";
            beta = hosts "X.lab.${domain}.";
            gamma = hosts "api.*.lab2.${domain}";
            delta = hosts "api.x.lab2.${domain}";
          };
          fail = [
            "myCaddy.apps: host `*.lab.${domain}` (myCaddy.apps.alpha) overlaps host `x.lab.${domain}` (myCaddy.apps.beta); only one route per host can be served."
            (caddyOverlap "api.x.lab2.${domain}" "delta" "api.*.lab2.${domain}" "gamma")
          ];
        };

        caddy-uncheckable-hosts-fail-closed = {
          module.myCaddy.apps = {
            unicode = hosts "bücher.${domain}";
            punycode = hosts "xn--bcher-kva.${domain}";
            port = hosts "port.${domain}:8443";
            partial = hosts "ab*.${domain}";
            placeholder = hosts "{http.request.host}";
          };
          fail = [
            "myCaddy.apps.unicode.host: `bücher.${domain}` cannot be checked for overlapping claims; write a plain ASCII hostname (Punycode for internationalized names) with no port or placeholder, using `*` only as a whole label."
            (caddyUncheckable "port" "port.${domain}:8443")
            (caddyUncheckable "partial" "ab*.${domain}")
            (caddyUncheckable "placeholder" "{http.request.host}")
          ];
        };

        caddy-host-repeated-in-one-matcher = {
          module.myCaddy.apps.beta = hosts "beta.${domain} Beta.${domain}.";
          fail = [
            "myCaddy.apps.beta.host: `beta.${domain}` is listed more than once in one matcher; this registry treats spellings differing only in case or a trailing dot as one host (stricter than Caddy, which rejects case-insensitive repeats)."
          ];
        };

        # Distinct names, a wildcard over names nobody else claims, and one
        # app's own wildcard covering its own exact name are all fine.
        caddy-distinct-hosts-pass = {
          module.myCaddy.apps = {
            alpha = hosts "alpha.${domain}";
            beta = hosts "beta.${domain} other.${domain}";
            gamma = hosts "*.wild.${domain} x.wild.${domain}";
            delta = hosts "x.wild2.${domain}";
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

        sqlite-unsafe-literal-names = {
          module = sqlite [
            "/srv/a/trim.db "
            "/srv/b/trim.db"
            "/srv/c/my db.db"
            "/srv/d/quo'te.db"
          ];
          fail = [
            "mySqliteQuiesce.apps.fixture.databases: `/srv/a/trim.db ` stages as `trim.db `, which sqlite's .backup cannot take unquoted; staged names may only use letters, digits and `._+@%,:=~-`."
            (sqliteUnsafe "/srv/c/my db.db" "my db.db")
            (sqliteUnsafe "/srv/d/quo'te.db" "quo'te.db")
          ];
        };

        # Runtime-named entries are left to the unit (see the runtime check),
        # including a glob tail that is only a name once the shell unescapes it.
        sqlite-distinct-passes = {
          module = sqlite [
            "/srv/one.db"
            "/srv/profiles/*/two.db"
            "/srv/dynamic/*.db"
            "/srv/more/*.db"
            "/srv/l/plain.db"
            "/srv/q*/plain\\.db"
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
      # creates the source databases (each recording its unrewritten path);
      # `previous` names a staged copy left by an earlier run, a real database
      # (recording `previous`) so that an overwrite would succeed silently; `stderr` and `staged` are the complete
      # expected error output and staging directory listing (hidden files
      # included) afterwards.
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

        # The shell unescapes `plain\.db` to `plain.db`.
        escaped-glob-tail-collides = {
          databases = [
            "${fx}/l/plain.db"
            "${fx}/q*/plain\\.db"
          ];
          setup = [
            "l/plain.db"
            "q1/plain.db"
          ];
          previous = "plain.db";
          status = 1;
          stderr = "mySqliteQuiesce: ${fx}/l/plain.db and ${fx}/q1/plain.db both stage to /var/backup/sqlite/rt-escaped-glob-tail-collides/plain.db; no staged copy was written";
          staged = [ "plain.db=previous" ];
        };

        # sqlite's unquoted .backup argument would drop the trailing space
        # and overwrite trim.db.
        unsafe-resolved-name-fails-closed = {
          databases = [
            "${fx}/t/trim.db"
            "${fx}/s/*"
          ];
          setup = [
            "t/trim.db"
            "s/trim.db "
          ];
          previous = "trim.db";
          status = 1;
          stderr = "mySqliteQuiesce: ${fx}/s/trim.db  stages as `trim.db `, which sqlite's .backup cannot take unquoted; no staged copy was written";
          staged = [ "trim.db=previous" ];
        };

        hidden-match-is-staged = {
          databases = [
            "${fx}/h/.*.db"
            "${fx}/v/visible.db"
          ];
          setup = [
            "h/.hidden.db"
            "v/visible.db"
          ];
          status = 0;
          staged = [
            ".hidden.db=${fx}/h/.hidden.db"
            "visible.db=${fx}/v/visible.db"
          ];
        };

        # A lone runtime-named entry is checked too: sqlite would write
        # `trim.db ` as trim.db over the previous copy.
        single-glob-unsafe-name-fails-closed = {
          databases = [ "${fx}/sg/*" ];
          setup = [ "sg/trim.db " ];
          previous = "trim.db";
          status = 1;
          stderr = "mySqliteQuiesce: ${fx}/sg/trim.db  stages as `trim.db `, which sqlite's .backup cannot take unquoted; no staged copy was written";
          staged = [ "trim.db=previous" ];
        };

        # `$(basename ...)` would strip the newline, validating and writing
        # bad.db; the raw name is rejected and nothing is copied.
        newline-name-fails-closed = {
          databases = [
            "${fx}/nl/*"
            "${fx}/nl2/other.db"
          ];
          setup = [
            "nl/bad.db\n"
            "nl2/other.db"
          ];
          previous = "bad.db";
          status = 1;
          stderr = "mySqliteQuiesce: ${fx}/nl/bad.db\n stages as `bad.db\n`, which sqlite's .backup cannot take unquoted; no staged copy was written";
          staged = [ "bad.db=previous" ];
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
              mkdir -p "$(dirname "$FX/"${lib.escapeShellArg f})"
              sqlite3 "$FX/"${lib.escapeShellArg f} "create table origin(path text); insert into origin values ('${fx}/${f}')"
            '') c.setup}
            ${lib.optionalString (c ? previous) ''
              sqlite3 "$dst/${c.previous}" "create table origin(path text); insert into origin values ('previous')"
            ''}
            rewrite < ${script} > "$name.sh"
            if bash "$name.sh" 2> "$name.err"; then rc=0; else rc=$?; fi
            [ "$rc" = ${toString c.status} ] || fail "$name: exit $rc, want ${toString c.status}"
            rewrite < ${expectedErr} | diff -u - "$name.err" > "$name.diff" || fail "$name: stderr differs" "$name.diff"
            # Hidden staged files count too.
            shopt -s dotglob nullglob
            for f in "$dst"/*; do
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
