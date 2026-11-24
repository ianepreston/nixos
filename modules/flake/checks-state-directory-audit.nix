# Synthetic compositions for the `myAppStateAudit` StateDirectory coverage
# audit (#1024). Each case evaluates a minimal NixOS system with the real
# app-state and preservation modules and inspects the audit's assertion
# and warning text. Nothing is built or booted; the derivation only
# reports the evaluated outcome.
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
      reason = "synthetic fixture";

      evalCase =
        module:
        (inputs.nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            inputs.self.modules.nixos.app-state
            inputs.preservation.nixosModules.default
            {
              system.stateVersion = "25.11";
              boot.loader.grub.enable = false;
              boot.initrd.systemd.enable = true;
              fileSystems."/" = {
                device = "none";
                fsType = "tmpfs";
              };
              preservation.enable = lib.mkDefault true;
            }
            module
          ];
        }).config;

      # A persistent native service: just enough unit for the audit.
      svc = serviceConfig: {
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = "${pkgs.coreutils}/bin/true";
        }
        // serviceConfig;
      };

      exemption = unit: directories: disposition: {
        inherit
          unit
          directories
          disposition
          reason
          ;
      };

      # `fail`: lines that must appear in a failing audit message.
      # `pass`: unit names that must not appear in any failing audit
      # message. `warn` / `noWarn`: substrings of the audit's warnings.
      cases = {
        omitted-coverage-fails = {
          module.systemd.services.omitted = svc { StateDirectory = "./sub//omitted/"; };
          fail = [ "omitted.service: /var/lib/sub/omitted" ];
        };

        exact-coverage-passes = {
          module = {
            systemd.services.exact = svc { StateDirectory = "exact"; };
            myAppState.exact.stateDir = "/var/lib/exact";
          };
          pass = [ "exact.service" ];
        };

        ancestor-coverage-passes = {
          module = {
            systemd.services.child = svc { StateDirectory = "parent/child"; };
            preservation.preserveAt."/persist".directories = [ "/var/lib/parent" ];
          };
          pass = [ "child.service" ];
        };

        unrelated-prefix-fails = {
          module = {
            systemd.services.foobar = svc { StateDirectory = "foobar"; };
            preservation.preserveAt."/persist".directories = [ "/var/lib/foo" ];
          };
          fail = [ "foobar.service: /var/lib/foobar" ];
        };

        dynamic-user-symlink-path-fails = {
          module = {
            systemd.services.dyn = svc {
              DynamicUser = true;
              StateDirectory = "dyn";
            };
            preservation.preserveAt."/persist".directories = [ "/var/lib/dyn" ];
          };
          fail = [ "dyn.service: /var/lib/private/dyn" ];
        };

        dynamic-user-private-path-passes = {
          module = {
            systemd.services.dyn = svc {
              DynamicUser = "yes";
              StateDirectory = "dyn";
            };
            myAppState.dyn = {
              stateDir = "/var/lib/private/dyn";
              dynamicUser = true;
            };
          };
          pass = [ "dyn.service" ];
        };

        multiple-directories-string = {
          module = {
            systemd.services.multi = svc { StateDirectory = "multi-a multi-b:multi-link"; };
            preservation.preserveAt."/persist".directories = [ "/var/lib/multi-a" ];
          };
          fail = [ "multi.service: /var/lib/multi-b" ];
          absent = [
            "multi.service: /var/lib/multi-a"
            "/var/lib/multi-link"
          ];
        };

        multiple-directories-list = {
          module = {
            systemd.services.multilist = svc {
              StateDirectory = [
                "ml-a"
                "ml-b"
              ];
            };
            preservation.preserveAt."/persist".directories = [ "/var/lib/ml-b" ];
          };
          fail = [ "multilist.service: /var/lib/ml-a" ];
          absent = [ "multilist.service: /var/lib/ml-b" ];
        };

        disposable-exemption-passes = {
          module = {
            systemd.services.scratch = svc { StateDirectory = "scratch"; };
            myAppStateAudit.exemptions.scratch = exemption "scratch.service" [
              "/var/lib/scratch"
            ] "disposable";
          };
          pass = [ "scratch.service" ];
          noWarn = [ "scratch.service" ];
        };

        pending-exemption-passes-and-warns = {
          module = {
            systemd.services.queue = svc {
              DynamicUser = true;
              StateDirectory = "queue";
            };
            myAppStateAudit.exemptions.queue = exemption "queue.service" [ "/var/lib/private/queue" ] "pending";
          };
          pass = [ "queue.service" ];
          warn = [ "queue.service state /var/lib/private/queue is not preserved" ];
        };

        stale-exemption-fails = {
          module = {
            systemd.services.kept = svc { StateDirectory = "kept"; };
            myAppState.kept.stateDir = "/var/lib/kept";
            myAppStateAudit.exemptions = {
              ghost = exemption "ghost.service" [ "/var/lib/ghost" ] "disposable";
              kept = exemption "kept.service" [ "/var/lib/kept" ] "disposable";
            };
          };
          fail = [
            "ghost.service: /var/lib/ghost"
            "kept.service: /var/lib/kept"
          ];
        };

        blank-reason-fails = {
          module = {
            systemd.services.blank = svc { StateDirectory = "blank"; };
            myAppStateAudit.exemptions.blank = exemption "blank.service" [ "/var/lib/blank" ] "disposable" // {
              reason = "  ";
            };
          };
          failText = [ "myAppStateAudit.exemptions.blank: `reason`" ];
        };

        disabled-unit-ignored = {
          module.systemd.services.off = svc { StateDirectory = "off"; } // {
            enable = false;
          };
          pass = [ "off.service" ];
        };

        no-preservation-no-audit = {
          module = {
            preservation.enable = false;
            systemd.services.omitted = svc { StateDirectory = "omitted"; };
          };
          noFailures = true;
        };
      };

      check =
        name: c:
        let
          cfg = evalCase c.module;
          failed = map (a: a.message) (
            lib.filter (a: !a.assertion && lib.hasPrefix "myAppStateAudit" a.message) cfg.assertions
          );
          text = lib.concatStringsSep "\n" failed;
          warnings = lib.filter (lib.hasPrefix "myAppStateAudit") cfg.warnings;
          has = line: lib.hasInfix "  ${line}\n" text;
          problems =
            map (l: "expected failure line `${l}`") (lib.filter (l: !has l) (c.fail or [ ]))
            ++ map (l: "expected failure text `${l}`") (
              lib.filter (l: !lib.hasInfix l text) (c.failText or [ ])
            )
            ++ map (l: "unexpected failure line `${l}`") (lib.filter has (c.absent or [ ]))
            ++ map (u: "unexpected failure for ${u}") (
              lib.filter (u: lib.hasInfix "  ${u}: " text) (c.pass or [ ])
            )
            ++ map (w: "expected warning `${w}`") (
              lib.filter (w: !lib.any (lib.hasInfix w) warnings) (c.warn or [ ])
            )
            ++ map (w: "unexpected warning `${w}`") (
              lib.filter (w: lib.any (lib.hasInfix w) warnings) (c.noWarn or [ ])
            )
            ++ lib.optional ((c.noFailures or false) && failed != [ ]) "expected no audit failures";
        in
        map (p: "${name}: ${p}\n--- audit output ---\n${text}") problems;

      problems = lib.concatLists (lib.mapAttrsToList check cases);
    in
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        state-directory-audit =
          pkgs.runCommand "state-directory-audit"
            {
              passAsFile = [ "report" ];
              report = lib.concatStringsSep "\n\n" problems;
            }
            ''
              ${
                if problems == [ ] then
                  ''echo "${toString (lib.length (lib.attrNames cases))} synthetic compositions passed"''
                else
                  ''cat "$reportPath"; exit 1''
              }
              touch "$out"
            '';
      };
    };
}
