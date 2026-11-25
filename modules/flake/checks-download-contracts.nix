# Contract checks for the download stack's consumers (#1022): shelfmark and
# decluttarr reach prowlarr, sabnzbd, sonarr and radarr only through the
# endpoints those apps publish in `myServiceEndpoints`, and decluttarr reads
# API keys only through their `myRuntimeCredentials.readers`.
#
# `download-contracts` extends tests-server, which imports every one of these
# apps, with synthetic producer changes (the services' real listening ports
# as well as the published endpoints, units and readers) and compares what
# both consumers render: container env, decluttarr's base URLs and ordering,
# and the endpoint/consumer assertion messages. `baseline` pins today's
# values.
#
# `download-contracts-decluttarr-runtime` runs decluttarr's real preStart
# against fixture key files (paths rewritten into the build directory, with a
# `sleep` stub counting retries): it renders the complete config.yaml, renders
# again on the next start, blocks on a missing key, follows a moved reader
# with no consumer change, writes a URL holding `$` and quotes as data, and
# runs a reader that needs jq.
{ inputs, ... }:
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
      extend = module: (base.extendModules { modules = [ module ]; }).config;
      arrLib = import ../apps/_arr-lib.nix;

      prefixes = [
        "myServiceEndpoints"
        "modules/apps/shelfmark.nix"
        "modules/apps/decluttarr.nix"
      ];
      # `assertion` first: some modules' messages only evaluate when failing.
      failures =
        cfg:
        lib.sort lib.lessThan (
          lib.filter (m: lib.any (p: lib.hasPrefix p m) prefixes) (
            map (a: a.message) (lib.filter (a: !a.assertion) cfg.assertions)
          )
        );

      # What the consumers render from the contracts.
      observe =
        cfg:
        let
          decluttarr = cfg.systemd.services.podman-decluttarr;
          env = cfg.virtualisation.oci-containers.containers.shelfmark.environment;
          # The printf arguments: a single-quoted JSON URL, then its key.
          baseUrls = lib.concatMap (
            l:
            let
              m = builtins.match " *'([^']*)' \"[$][a-z]+_key\".*" l;
            in
            lib.optional (m != null) (builtins.fromJSON (lib.head m))
          ) (lib.splitString "\n" decluttarr.preStart);
        in
        {
          shelfmark = { inherit (env) PROWLARR_URL SABNZBD_URL; };
          decluttarr = {
            inherit baseUrls;
            inherit (decluttarr) after wants;
          };
          failures = failures cfg;
        };

      hci = port: "http://host.containers.internal:${toString port}";
      upstreamUnits = [
        "sonarr.service"
        "radarr.service"
        "sabnzbd.service"
      ];
      # Expected observation; each case overrides what it changes.
      expect =
        {
          prowlarr ? hci 9696,
          sabnzbd ? hci 18080,
          sonarr ? hci 8989,
          radarr ? hci 7878,
          units ? upstreamUnits,
          failures ? [ ],
        }:
        {
          shelfmark = {
            PROWLARR_URL = prowlarr;
            SABNZBD_URL = sabnzbd;
          };
          decluttarr = {
            baseUrls = [
              sonarr
              radarr
              sabnzbd
            ];
            # oci-containers' own ordering comes first.
            after = [ "network-online.target" ] ++ units;
            wants = [ "network-online.target" ] ++ units;
          };
          failures = lib.sort lib.lessThan failures;
        };

      endpointProblem =
        problem: name: url:
        "myServiceEndpoints.${name}.containerUrl: `${url}` ${problem}.";
      endpointMessage = endpointProblem "must be an absolute URL whose host a container can reach (normally host.containers.internal); a loopback or wildcard host names the container itself";
      userinfoMessage = endpointProblem "carries userinfo (`user@` before the host); a container URL must not embed credentials";
      controlMessage = endpointProblem "contains whitespace or a control character";
      consumerMessage =
        consumer: name:
        "modules/apps/${consumer}.nix runs in a container and needs myServiceEndpoints.${name}.containerUrl, published by modules/apps/${name}.nix.";
      fixtureEndpoint = containerUrl: {
        url = "http://127.0.0.1:1";
        inherit containerUrl;
        unit = "fixture.service";
      };
      # `<prefix>-<index>` endpoints, one per container URL.
      fixtureName = prefix: i: "${prefix}-${toString i}";
      fixtureEndpoints =
        prefix: urls:
        lib.listToAttrs (
          lib.imap0 (i: u: lib.nameValuePair (fixtureName prefix i) (fixtureEndpoint u)) urls
        );
      # Credentials in the authority, whatever the host.
      userinfoUrls = [
        "http://user@host.containers.internal:1/x"
        "http://@host.containers.internal:1"
        "http://user@localhost:1"
        "http://user:pw@127.0.0.1:1"
      ];
      # URL parsers strip these, so `local<TAB>host` would read as localhost.
      controlUrls = [
        "http://local\thost:1"
        "http://local\nhost:1"
        "http://local host:1"
        "http://localhost\r:1"
        "\thttp://host.containers.internal:1"
        "http://host.containers.internal:1/a b"
      ];
      rejectedUrls = [
        # Loopback and "this host" names, with case, port and trailing dots.
        "http://LocalHost:1/"
        "http://localhost.:1"
        "http://LOCALHOST..:1"
        "http://app.localhost"
        "http://app.localhost."
        "https://127.1.2.3:8443/path"
        "http://127.0.0.1.:1"
        "http://0.0.0.0:1"
        # Non-canonical numeric spellings a resolver reads as 127.0.0.1.
        "http://2130706433"
        "http://0x7f.1"
        "http://0177.0.0.1"
        "http://127.000.0.1"
        # IPv6 loopback and wildcard, compressed, expanded and zero-padded,
        # with a zone, and IPv4-mapped or -compatible.
        "http://[::1]:1"
        "http://[0:0:0:0:0:0:0:1]:1"
        "http://[::0001]"
        "http://[::1%25eth0]:1"
        "http://[::]:1"
        "http://[0::0]"
        "http://[0:0:0:0:0:0:0:0]"
        "http://[::ffff:127.0.0.1]:1"
        "http://[::FFFF:7f00:1]"
        "http://[::ffff:0.0.0.0]"
        "http://[::127.0.0.1]"
        # Not an absolute URL with a plain host.
        "host.containers.internal:1"
        "http://:1"
        "http://%6cocalhost"
        "http://[fd00::1::2]"
        "http://[1:2:3:4:5:6:7:8:9]"
        "http://[::ffff:256.0.0.1]"
      ];
      acceptedUrls = [
        (hci 1)
        # Credential-free, with an `@` only in the query.
        "http://host.containers.internal:1/x"
        "http://host.containers.internal/x?to=a@b"
        "http://host.containers.internal.:1"
        "https://10.88.0.1:443/x"
        "http://127-0-0-1.example:1"
        "http://[fd00::1]:80"
        "http://[1:2:3:4:5:6:7:8]"
        "http://[::ffff:10.88.0.1]:1"
        "http://[::ffff:a00:1]"
        "http://[fd00::10.0.0.1]"
      ];

      cases = {
        baseline = {
          module = { };
          want = expect { };
        };

        # A producer's published endpoint is the only thing the consumers
        # read, so changing it moves both of them and nothing else.
        producer-ports-propagate = {
          module.myServiceEndpoints = {
            prowlarr.containerUrl = lib.mkForce (hci 19696);
            sabnzbd.containerUrl = lib.mkForce (hci 18181);
            sonarr.containerUrl = lib.mkForce (hci 18989);
            radarr.containerUrl = lib.mkForce (hci 17878);
          };
          want = expect {
            prowlarr = hci 19696;
            sabnzbd = hci 18181;
            sonarr = hci 18989;
            radarr = hci 17878;
          };
        };

        # The producers publish the port their service actually listens
        # on, so moving the listener moves both consumers.
        listener-ports-propagate = {
          module.services = {
            prowlarr.settings.server.port = lib.mkForce 19696;
            sabnzbd.settings.misc.port = lib.mkForce 18181;
            sonarr.settings.server.port = lib.mkForce 18989;
            radarr.settings.server.port = lib.mkForce 17878;
          };
          want = expect {
            prowlarr = hci 19696;
            sabnzbd = hci 18181;
            sonarr = hci 18989;
            radarr = hci 17878;
          };
        };

        # The producers' port pins are defaults, so a host's plain
        # assignment wins without a priority override.
        listener-ports-plain-assignment = {
          module.services = {
            prowlarr.settings.server.port = 19696;
            sabnzbd.settings.misc.port = 18181;
            sonarr.settings.server.port = 18989;
            radarr.settings.server.port = 17878;
          };
          want = expect {
            prowlarr = hci 19696;
            sabnzbd = hci 18181;
            sonarr = hci 18989;
            radarr = hci 17878;
          };
        };

        # The key reader still names sabnzbd.service, so both stay.
        producer-unit-propagates = {
          module.myServiceEndpoints.sabnzbd.unit = lib.mkForce "sabnzbd-next.service";
          want = expect {
            units = [
              "sonarr.service"
              "radarr.service"
              "sabnzbd-next.service"
              "sabnzbd.service"
            ];
          };
        };

        # A moved key file and key-writing unit reach decluttarr with no
        # consumer edit; its preStart reads the moved file (the runtime check
        # proves it renders from there).
        producer-credential-moves = {
          module.myRuntimeCredentials.readers.SONARR_API_KEY = {
            readScript = lib.mkForce (arrLib.mkArrApiKeyScript "/srv/moved/sonarr/config.xml");
            sourceUnit = lib.mkForce "sonarr-keys.service";
          };
          want = expect {
            units = [
              "sonarr.service"
              "sonarr-keys.service"
              "radarr.service"
              "sabnzbd.service"
            ];
          };
        };

        # A producer that stops publishing a container URL blocks every
        # container consumer instead of handing it an empty or loopback URL.
        missing-container-url-blocks-consumers = {
          module.myServiceEndpoints.sabnzbd.containerUrl = lib.mkForce null;
          want = expect {
            sabnzbd = "";
            failures = [
              (consumerMessage "decluttarr" "sabnzbd")
              (consumerMessage "shelfmark" "sabnzbd")
            ];
          };
        };

        # Every spelling of a loopback or wildcard host, and anything that
        # is not an absolute URL with a plain host, is refused.
        loopback-container-urls-rejected = {
          module.myServiceEndpoints = {
            prowlarr.containerUrl = lib.mkForce "http://127.0.0.1:9696";
          }
          // fixtureEndpoints "loopback" rejectedUrls
          // fixtureEndpoints "userinfo" userinfoUrls
          // fixtureEndpoints "control" controlUrls;
          want = expect {
            prowlarr = "http://127.0.0.1:9696";
            failures = [
              (endpointMessage "prowlarr" "http://127.0.0.1:9696")
            ]
            ++ lib.imap0 (i: endpointMessage (fixtureName "loopback" i)) rejectedUrls
            ++ lib.imap0 (i: userinfoMessage (fixtureName "userinfo" i)) userinfoUrls
            ++ lib.imap0 (i: controlMessage (fixtureName "control" i)) controlUrls;
          };
        };

        # Reachable hosts pass, and a host-only endpoint may omit the
        # container URL altogether.
        reachable-container-urls-pass = {
          module.myServiceEndpoints = fixtureEndpoints "accepted" acceptedUrls // {
            host-only = fixtureEndpoint null;
          };
          want = expect { };
        };
      };

      problems = lib.concatLists (
        lib.mapAttrsToList (
          name: c:
          let
            got = observe (extend c.module);
          in
          lib.optional (got != c.want) ''
            ${name}: consumer configuration differs
              want: ${builtins.toJSON c.want}
              got:  ${builtins.toJSON got}''
        ) cases
      );

      # Runtime cases share one /run/decluttarr, in order, so a later start
      # sees what an earlier one left. `keys` writes fixture key files
      # (absent: none); `config` selects the composition whose preStart runs.
      movedConfig = extend cases.producer-credential-moves.module;
      # A valid URL holding shell and YAML metacharacters, and a sabnzbd
      # reader that needs jq from `readerPath`.
      oddUrl = "http://host.containers.internal:8989/$status?q=%41&x=\"y\"`z`";
      oddConfig = extend {
        myServiceEndpoints.sonarr.containerUrl = lib.mkForce oddUrl;
        myRuntimeCredentials.readers.SABNZBD_API_KEY.readScript = lib.mkForce "jq -r .misc.api_key /var/lib/sabnzbd/keys.json";
      };
      unitPath = lib.makeBinPath base.config.systemd.services.podman-decluttarr.path;
      script = cfg: pkgs.writeText "decluttarr-prestart" cfg.systemd.services.podman-decluttarr.preStart;
      arrXml = key: "<Config><ApiKey>${key}</ApiKey></Config>";
      sabIni = key: "[misc]\nhost = 0.0.0.0\n  api_key = ${key}  \nnzb_key = other\n";
      configYaml =
        {
          sonarr,
          radarr,
          sabnzbd,
          sonarrUrl ? "http://host.containers.internal:8989",
        }:
        ''
          general:
            log_level: INFO
            timer: 10
            test_run: false

          job_defaults:
            max_strikes: 3
            min_days_between_searches: 7
            max_concurrent_searches: 3

          jobs:
            remove_failed_imports:
              message_patterns:
                - "Not a Custom Format upgrade for existing*"
                - "Not an upgrade for existing*"
                - "*Found potentially dangerous file with extension*"
                - "Invalid video file*"
                - "No files found are eligible for import*"
                - "One or more episodes expected in this release were not imported or missing from the release"
            remove_failed_downloads:
            remove_stalled:
            remove_metadata_missing:
            remove_unmonitored:
            remove_orphans:
            remove_missing_files:

          instances:
            sonarr:
              - base_url: ${builtins.toJSON sonarrUrl}
                api_key: "${sonarr}"
            radarr:
              - base_url: "http://host.containers.internal:7878"
                api_key: "${radarr}"

          download_clients:
            sabnzbd:
              - base_url: "http://host.containers.internal:18080"
                api_key: "${sabnzbd}"
                name: "SABnzbd"
        '';
      sonarrXml = "var/lib/sonarr/.config/NzbDrone/config.xml";
      radarrXml = "var/lib/radarr/.config/Radarr/config.xml";
      sabnzbdIni = "var/lib/sabnzbd/sabnzbd.ini";
      runtimeCases = [
        {
          name = "renders-every-key";
          keys = {
            ${sonarrXml} = arrXml "sonarr-1";
            ${radarrXml} = arrXml "radarr-1";
            ${sabnzbdIni} = sabIni "sab-1";
          };
          status = 0;
          sleeps = 0;
          rendered = configYaml {
            sonarr = "sonarr-1";
            radarr = "radarr-1";
            sabnzbd = "sab-1";
          };
        }
        {
          # The next container start re-reads every key.
          name = "rerenders-on-next-start";
          keys = {
            ${sonarrXml} = arrXml "sonarr-2";
            ${radarrXml} = arrXml "radarr-2";
            ${sabnzbdIni} = sabIni "sab-2";
          };
          status = 0;
          sleeps = 0;
          rendered = configYaml {
            sonarr = "sonarr-2";
            radarr = "radarr-2";
            sabnzbd = "sab-2";
          };
        }
        {
          # First boot: the key appears while the start is retrying.
          name = "late-key-is-awaited";
          keys = {
            ${sonarrXml} = arrXml "sonarr-3";
            ${radarrXml} = arrXml "radarr-3";
          };
          late = {
            ${sabnzbdIni} = sabIni "sab-3";
          };
          status = 0;
          sleeps = 2;
          rendered = configYaml {
            sonarr = "sonarr-3";
            radarr = "radarr-3";
            sabnzbd = "sab-3";
          };
        }
        {
          # A key that never appears fails the start after ten tries and
          # leaves the previous render alone.
          name = "missing-key-blocks-start";
          keys = {
            ${sonarrXml} = arrXml "sonarr-4";
            ${radarrXml} = "<Config></Config>";
            ${sabnzbdIni} = sabIni "sab-4";
          };
          status = 1;
          sleeps = 10;
          stderr = "decluttarr-config: failed to read radarr after retries\n";
          rendered = configYaml {
            sonarr = "sonarr-3";
            radarr = "radarr-3";
            sabnzbd = "sab-3";
          };
        }
        {
          # The moved reader from producer-credential-moves, unchanged
          # consumer: only the new location holds the sonarr key.
          name = "moved-reader-needs-no-consumer-edit";
          config = movedConfig;
          keys = {
            "srv/moved/sonarr/config.xml" = arrXml "sonarr-5";
            ${radarrXml} = arrXml "radarr-5";
            ${sabnzbdIni} = sabIni "sab-5";
          };
          status = 0;
          sleeps = 0;
          rendered = configYaml {
            sonarr = "sonarr-5";
            radarr = "radarr-5";
            sabnzbd = "sab-5";
          };
        }
        {
          # The URL is written as data, not expanded, and a reader using a
          # `readerPath` tool works.
          name = "literal-url-and-jq-reader";
          config = oddConfig;
          keys = {
            ${sonarrXml} = arrXml "sonarr-6";
            ${radarrXml} = arrXml "radarr-6";
            "var/lib/sabnzbd/keys.json" = ''{"misc":{"api_key":"sab-6"}}'';
          };
          status = 0;
          sleeps = 0;
          rendered = configYaml {
            sonarr = "sonarr-6";
            radarr = "radarr-6";
            sabnzbd = "sab-6";
            sonarrUrl = oddUrl;
          };
        }
      ];

      writeKeys =
        dir: keys:
        lib.concatStrings (
          lib.mapAttrsToList (path: content: ''
            mkdir -p "$(dirname "${dir}/${path}")"
            printf '%s' ${lib.escapeShellArg content} > "${dir}/${path}"
          '') keys
        );

      runtimeCase =
        c:
        let
          inherit (c) name;
          expected = pkgs.writeText "${name}-config.yaml" c.rendered;
          expectedErr = pkgs.writeText "${name}-stderr" (c.stderr or "");
        in
        ''
          (
            rm -rf "$FX" "$LATE"
            mkdir -p "$FX" "$LATE"
            ${writeKeys "$FX" c.keys}
            ${writeKeys "$LATE" (c.late or { })}
            echo 0 > "$SLEEPS"
            rewrite < ${script (c.config or base.config)} > ${name}.sh
            if PATH="$STUB:${unitPath}" ${pkgs.runtimeShell} ${name}.sh 2> ${name}.err; then rc=0; else rc=$?; fi
            [ "$rc" = ${toString c.status} ] || fail "${name}: exit $rc, want ${toString c.status}" ${name}.err
            [ "$(cat "$SLEEPS")" = ${toString c.sleeps} ] || fail "${name}: slept $(cat "$SLEEPS") times, want ${toString c.sleeps}"
            diff -u ${expectedErr} ${name}.err > ${name}.ediff || fail "${name}: stderr differs" ${name}.ediff
            diff -u ${expected} "$RUN/config.yaml" > ${name}.diff || fail "${name}: config.yaml differs" ${name}.diff
            [ "$(stat -c %a "$RUN/config.yaml")" = 444 ] || fail "${name}: config.yaml mode $(stat -c %a "$RUN/config.yaml")"
            [ ! -e "$RUN/config.yaml.tmp" ] || fail "${name}: config.yaml.tmp left behind"
          )
        '';

      # Counts retries; on the second, moves the case's `late` keys in.
      sleepStub = pkgs.writeShellScriptBin "sleep" ''
        n=$(( $(cat "$SLEEPS") + 1 ))
        echo "$n" > "$SLEEPS"
        if [ "$n" = 2 ]; then cp -r "$LATE/." "$FX/"; fi
      '';
    in
    {
      # Evaluates a full host configuration, so only once, for the system
      # the servers run.
      checks = lib.optionalAttrs (system == "x86_64-linux") {
        download-contracts =
          pkgs.runCommand "download-contracts"
            {
              passAsFile = [ "report" ];
              report = lib.concatStringsSep "\n\n" problems;
            }
            ''
              ${
                if problems == [ ] then
                  ''echo "${toString (lib.length (lib.attrNames cases))} download-contract compositions passed"''
                else
                  ''cat "$reportPath"; exit 1''
              }
              touch "$out"
            '';

        download-contracts-decluttarr-runtime =
          pkgs.runCommand "download-contracts-decluttarr-runtime" { nativeBuildInputs = [ pkgs.diffutils ]; }
            ''
              FX="$PWD/fx"
              LATE="$PWD/late"
              RUN="$PWD/run/decluttarr"
              SLEEPS="$PWD/sleeps"
              STUB=${sleepStub}/bin
              export FX LATE SLEEPS
              mkdir -p "$RUN"
              rewrite() { sed -e "s|/run/decluttarr|$RUN|g" -e "s|/var/lib/|$FX/var/lib/|g" -e "s|/srv/moved/|$FX/srv/moved/|g"; }
              : > failures
              fail() {
                echo "$1" >> failures
                if [ -n "''${2:-}" ]; then cat "$2" >> failures; fi
              }
              ${lib.concatMapStrings runtimeCase runtimeCases}
              if [ -s failures ]; then
                cat failures
                exit 1
              fi
              echo "${toString (lib.length runtimeCases)} decluttarr start cases passed"
              touch "$out"
            '';
      };
    };
}
