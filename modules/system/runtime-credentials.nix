# Runtime credential readers.
# Several apps generate their own API key on first start and keep it in
# a config file the operator never types out (the *arrs' config.xml,
# sabnzbd's ini, jellyfin's sqlite). Other services need those keys at
# runtime: homepage renders them into widget configs, shelfmark reads
# prowlarr's and sabnzbd's out of its environment to wire the search /
# download path. The keys can't live in sops — nothing chose them —
# and they mustn't land in /nix/store, so they're read off disk at boot
# into a tmpfs env file the consumer picks up.
#
# Two halves, contributed from opposite directions:
#   * `readers.<VAR>`      — declared by the app that *owns* the key,
#                            next to the service that generates it.
#   * `consumers.<name>`   — declared by the service that *needs* keys,
#                            listing which readers it wants and which
#                            units consume the resulting env file.
#
# Each consumer gets its own oneshot writing /run/<name>-credentials/env,
# ordered after every source unit it reads from and before the units
# that consume it. Per-credential reads retry briefly so first-boot
# timing (app just started, config not yet written) isn't fatal; an
# empty result skips that line rather than failing the unit, so a
# consumer comes up with one broken integration instead of not coming
# up at all.
#
# Lives in its own file rather than inline next to a consumer because
# there are two of them (homepage, shelfmark) pulling from the same
# reader registry — same rationale as sqlite-quiesce.nix.
_: {
  flake.modules.nixos.runtime-credentials =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (config.myRuntimeCredentials) readers consumers;
    in
    {
      options.myRuntimeCredentials = {
        readers = lib.mkOption {
          default = { };
          description = ''
            Registry of readable credentials, keyed by the env var name
            consumers will see (e.g. `PROWLARR_API_KEY`). Declared by
            the app module that owns the generating service; consuming
            it is a separate opt-in via `consumers.<name>.vars`.
          '';
          type = lib.types.attrsOf (
            lib.types.submodule (_: {
              options = {
                sourceUnit = lib.mkOption {
                  type = lib.types.str;
                  description = ''
                    Systemd unit that produces the config file or DB the
                    reader pulls from. Pulled into After=/Wants= on every
                    consumer that reads this credential, so the upstream
                    service has started (and on first boot, has written
                    its config) before we try to read it.
                  '';
                };
                readScript = lib.mkOption {
                  type = lib.types.lines;
                  description = ''
                    Shell snippet that prints the credential value to
                    stdout (no trailing newline). Runs as root with
                    coreutils + gnugrep + gnused + gawk + jq + sqlite on
                    PATH. Empty/missing output is tolerated — the env
                    line is omitted rather than blocking the consumer.
                  '';
                };
              };
            })
          );
        };

        consumers = lib.mkOption {
          default = { };
          description = ''
            Services that need credentials at runtime. Each entry emits
            a `<name>-credentials.service` oneshot rendering the
            requested readers into `envFile`, which the consuming units
            read via `EnvironmentFile=` (or podman's `--env-file`).
          '';
          type = lib.types.attrsOf (
            lib.types.submodule (
              { name, ... }:
              {
                options = {
                  vars = lib.mkOption {
                    type = lib.types.listOf lib.types.str;
                    description = ''
                      Reader names to render into this consumer's env
                      file. Every entry must exist in `readers` — an
                      assertion catches typos at eval time.
                    '';
                  };
                  envVarPrefix = lib.mkOption {
                    type = lib.types.str;
                    default = "";
                    description = ''
                      Prepended to each reader name in the rendered file.
                      Homepage needs `HOMEPAGE_VAR_` on anything it
                      substitutes into widget config; most consumers
                      read the bare name and leave this empty.
                    '';
                  };
                  units = lib.mkOption {
                    type = lib.types.listOf lib.types.str;
                    description = ''
                      Units that consume `envFile`. Ordered after the
                      oneshot, and restarted by it whenever it runs —
                      an env-file change doesn't bust a unit's drv hash,
                      so a plain `nixos-rebuild switch` wouldn't
                      otherwise pick up a rotated key.
                    '';
                  };
                  envFile = lib.mkOption {
                    type = lib.types.str;
                    default = "/run/${name}-credentials/env";
                    readOnly = true;
                    description = "Path of the rendered env file. Read-only; reference it from the consuming service.";
                  };
                };
              }
            )
          );
        };
      };

      # No `mkIf` guard on this block: every emitter maps over
      # `consumers`, so an empty set already yields nothing, and a guard
      # whose condition reads `consumers` would risk a definition cycle
      # with modules that reference `consumers.<name>.envFile`.
      config = {
        assertions = lib.concatLists (
          lib.mapAttrsToList (
            name: consumer:
            map (v: {
              assertion = readers ? ${v};
              message = "myRuntimeCredentials.consumers.${name}: no reader declared for '${v}'";
            }) consumer.vars
          ) consumers
        );

        systemd.services = lib.mkMerge [
          (lib.mapAttrs' (
            name: consumer:
            let
              used = lib.filterAttrs (v: _: lib.elem v consumer.vars) readers;
              sourceUnits = lib.unique (lib.mapAttrsToList (_: c: c.sourceUnit) used);
            in
            lib.nameValuePair "${name}-credentials" {
              description = "Render ${name} runtime credentials env file";
              after = [ "sops-install-secrets.service" ] ++ sourceUnits;
              wants = sourceUnits;
              before = consumer.units;
              wantedBy = consumer.units;
              path = with pkgs; [
                coreutils
                gnugrep
                gnused
                gawk
                jq
                sqlite
              ];
              serviceConfig = {
                Type = "oneshot";
                RemainAfterExit = true;
                RuntimeDirectory = "${name}-credentials";
                RuntimeDirectoryPreserve = "yes";
                UMask = "0077";
              };
              script = ''
                set -uo pipefail
                out=${consumer.envFile}
                tmp="$out.tmp"
                : > "$tmp"
                ${lib.concatStringsSep "\n" (
                  lib.mapAttrsToList (envVar: cred: ''
                    val=""
                    for _ in 1 2 3 4 5; do
                      raw="$( {
                      ${cred.readScript}
                      } 2>/dev/null || true)"
                      val="$(printf '%s' "$raw" | tr -d '\n\r' | head -c 256)"
                      [ -n "$val" ] && break
                      sleep 2
                    done
                    if [ -n "$val" ]; then
                      printf '%s=%s\n' '${consumer.envVarPrefix}${envVar}' "$val" >> "$tmp"
                    else
                      echo "${name}-credentials: empty value for ${consumer.envVarPrefix}${envVar} (sourceUnit=${cred.sourceUnit}), skipping" >&2
                    fi
                  '') used
                )}
                chmod 0400 "$tmp"
                mv "$tmp" "$out"
                # `--no-block` is required: the consumers have
                # After=<name>-credentials.service, so a blocking
                # try-restart enqueues a job that waits for *us* to
                # finish, deadlocking the unit forever. With --no-block,
                # systemd enqueues the restart and returns immediately,
                # letting this oneshot exit so the restart can proceed.
                ${pkgs.systemd}/bin/systemctl --no-block try-restart ${lib.concatStringsSep " " consumer.units} || true
              '';
            }
          ) consumers)

          # Consuming units order themselves after their renderer. Kept
          # separate from the block above so a unit consuming two
          # credential sets (none today) would merge rather than clash.
          (lib.mkMerge (
            lib.concatLists (
              lib.mapAttrsToList (
                name: consumer:
                map (unit: {
                  ${lib.removeSuffix ".service" unit} = {
                    after = [ "${name}-credentials.service" ];
                    wants = [ "${name}-credentials.service" ];
                  };
                }) consumer.units
              ) consumers
            )
          ))
        ];
      };
    };
}
