# Contract checks for the download stack's consumers (#1022): shelfmark and
# decluttarr reach prowlarr, sabnzbd, sonarr and radarr only through the
# endpoints those apps publish in `myServiceEndpoints`, and decluttarr reads
# API keys only through their `myRuntimeCredentials.readers`.
#
# `download-contracts` extends tests-server, which imports every one of these
# apps, with synthetic producer changes and compares what both consumers
# render: container env, decluttarr's base URLs and ordering, and the
# endpoint/consumer assertion messages. `baseline` pins today's values.
#
# `download-contracts-decluttarr-runtime` runs decluttarr's real preStart
# against fixture key files (paths rewritten into the build directory, with a
# `sleep` stub counting retries): it renders the complete config.yaml, renders
# again on the next start, blocks on a missing key, and follows a moved
# reader with no consumer change.
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
          baseUrls = lib.concatMap (
            l:
            let
              m = builtins.match " *- base_url: \"(.*)\"" l;
            in
            lib.optional (m != null) (lib.head m)
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
          inherit failures;
        };

      endpointMessage =
        name: url:
        "myServiceEndpoints.${name}.containerUrl: `${url}` must be an absolute URL whose host a container can reach (normally host.containers.internal); a loopback or wildcard host names the container itself.";
      consumerMessage =
        consumer: name:
        "modules/apps/${consumer}.nix runs in a container and needs myServiceEndpoints.${name}.containerUrl, published by modules/apps/${name}.nix.";
      fixtureEndpoint = containerUrl: {
        url = "http://127.0.0.1:1";
        inherit containerUrl;
        unit = "fixture.service";
      };

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

        loopback-container-urls-rejected = {
          module.myServiceEndpoints = {
            prowlarr.containerUrl = lib.mkForce "http://127.0.0.1:9696";
            lo-name = fixtureEndpoint "http://LocalHost:1/";
            lo-sub = fixtureEndpoint "http://app.localhost";
            lo-v4 = fixtureEndpoint "https://127.1.2.3:8443/path";
            lo-v6 = fixtureEndpoint "http://[::1]:1";
            any-v4 = fixtureEndpoint "http://0.0.0.0:1";
            any-v6 = fixtureEndpoint "http://[::]:1";
            relative = fixtureEndpoint "host.containers.internal:1";
            empty-host = fixtureEndpoint "http://:1";
          };
          want = expect {
            prowlarr = "http://127.0.0.1:9696";
            failures = [
              (endpointMessage "any-v4" "http://0.0.0.0:1")
              (endpointMessage "any-v6" "http://[::]:1")
              (endpointMessage "empty-host" "http://:1")
              (endpointMessage "lo-name" "http://LocalHost:1/")
              (endpointMessage "lo-sub" "http://app.localhost")
              (endpointMessage "lo-v4" "https://127.1.2.3:8443/path")
              (endpointMessage "lo-v6" "http://[::1]:1")
              (endpointMessage "prowlarr" "http://127.0.0.1:9696")
              (endpointMessage "relative" "host.containers.internal:1")
            ];
          };
        };

        # Reachable hosts pass, and a host-only endpoint may omit the
        # container URL altogether.
        reachable-container-urls-pass = {
          module.myServiceEndpoints = {
            bridge-name = fixtureEndpoint (hci 1);
            bridge-v4 = fixtureEndpoint "https://10.88.0.1:443/x";
            bridge-v6 = fixtureEndpoint "http://[fd00::1]:80";
            loopback-like = fixtureEndpoint "http://127-0-0-1.example:1";
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
      unitPath = lib.makeBinPath base.config.systemd.services.podman-decluttarr.path;
      script = cfg: pkgs.writeText "decluttarr-prestart" cfg.systemd.services.podman-decluttarr.preStart;
      arrXml = key: "<Config><ApiKey>${key}</ApiKey></Config>";
      sabIni = key: "[misc]\nhost = 0.0.0.0\n  api_key = ${key}  \nnzb_key = other\n";
      configYaml =
        {
          sonarr,
          radarr,
          sabnzbd,
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
              - base_url: "http://host.containers.internal:8989"
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
