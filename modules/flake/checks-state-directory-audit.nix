# Synthetic compositions for the `myAppStateAudit` StateDirectory coverage
# audit (#1024). Each case evaluates a minimal NixOS system with the real
# app-state and preservation modules and compares the audit's complete
# set of failure lines and warnings with the expected ones. Nothing is
# built or booted; the derivation only reports the evaluated outcome.
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

      # Base system with no StateDirectory of its own left uncovered
      # (`baseline-clean` proves it), so each case sees only its units.
      # dhcpcd is off and /var/lib/systemd (linger-users) is preserved, as
      # on the real servers.
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
              networking.useDHCP = false;
              preservation.enable = lib.mkDefault true;
              preservation.preserveAt."/persist".directories = [ "/var/lib/systemd" ];
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

      pendingWarning =
        unit: dir: owner:
        "myAppStateAudit: ${unit} state ${dir} is not preserved and awaits an owner decision (exemptions.${owner}): ${reason}";

      # `fail`: the complete set of failure lines (without the two-space
      # indent) across every audit assertion. `warn`: the complete set of
      # audit warnings. Both default to none.
      cases = {
        baseline-clean = {
          module = { };
        };

        omitted-coverage-fails = {
          module.systemd.services.omitted = svc { StateDirectory = "./sub//omitted/"; };
          fail = [ "omitted.service: /var/lib/sub/omitted" ];
        };

        exact-coverage-passes = {
          module = {
            systemd.services.exact = svc { StateDirectory = "exact"; };
            myAppState.exact.stateDir = "/var/lib/exact";
          };
        };

        ancestor-coverage-passes = {
          module = {
            systemd.services.child = svc { StateDirectory = "parent/child"; };
            preservation.preserveAt."/persist".directories = [ "/var/lib/parent" ];
          };
        };

        unrelated-prefix-fails = {
          module = {
            systemd.services.foobar = svc { StateDirectory = "foobar"; };
            preservation.preserveAt."/persist".directories = [ "/var/lib/foo" ];
          };
          fail = [ "foobar.service: /var/lib/foobar" ];
        };

        intermediate-does-not-cover = {
          module = {
            systemd.services.kept-child = svc { StateDirectory = "kept/child"; };
            preservation.preserveAt."/persist".directories = [
              {
                directory = "/var/lib/kept";
                how = "_intermediate";
              }
            ];
          };
          fail = [ "kept-child.service: /var/lib/kept/child" ];
        };

        user-directories-cover = {
          module = {
            users.users.svcuser = {
              isSystemUser = true;
              group = "svcuser";
              home = "/var/lib/svcuser";
            };
            users.groups.svcuser = { };
            # Preservation adds the home itself as an `_intermediate`
            # parent, which must not cover the sibling below.
            preservation.preserveAt."/persist".users.svcuser.directories = [ "data" ];
            systemd.services.svcdata = svc { StateDirectory = "svcuser/data svcuser/other"; };
          };
          fail = [ "svcdata.service: /var/lib/svcuser/other" ];
        };

        whitespace-separates-entries = {
          module = {
            systemd.services.ws = svc { StateDirectory = "kept/child\tomitted\nalso-omitted"; };
            preservation.preserveAt."/persist".directories = [ "/var/lib/kept" ];
          };
          fail = [
            "ws.service: /var/lib/also-omitted"
            "ws.service: /var/lib/omitted"
          ];
        };

        empty-assignment-resets = {
          module.systemd.services.reset = svc {
            StateDirectory = [
              "before"
              ""
              "after"
            ];
          };
          fail = [ "reset.service: /var/lib/after" ];
        };

        invalid-entries-fail-closed = {
          module.systemd.services.bad = svc {
            StateDirectory = [
              "/var/lib/abs"
              "../escape"
              "a/../b"
              "\"quoted dir\""
              "fine"
            ];
          };
          fail = [
            "bad.service: /var/lib/fine"
            "bad.service: StateDirectory value `/var/lib/abs` (systemd rejects absolute paths)"
            "bad.service: StateDirectory value `../escape` (systemd rejects `..` components)"
            "bad.service: StateDirectory value `a/../b` (systemd rejects `..` components)"
            "bad.service: StateDirectory value `\"quoted` (quoted entries are not parsed by this audit)"
            "bad.service: StateDirectory value `dir\"` (quoted entries are not parsed by this audit)"
          ];
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
        };

        dynamic-user-spellings = {
          module.systemd.services = {
            upper-y = svc {
              DynamicUser = "Y";
              StateDirectory = "upper-y";
            };
            mixed-on = svc {
              DynamicUser = "On";
              StateDirectory = "mixed-on";
            };
            upper-off = svc {
              DynamicUser = "OFF";
              StateDirectory = "upper-off";
            };
            last-wins = svc {
              DynamicUser = [
                false
                true
              ];
              StateDirectory = "last-wins";
            };
            reset = svc {
              DynamicUser = [
                true
                ""
              ];
              StateDirectory = "du-reset";
            };
            garbage = svc {
              DynamicUser = "maybe";
              StateDirectory = "garbage";
            };
          };
          fail = [
            "garbage.service: /var/lib/garbage"
            "garbage.service: DynamicUser value `maybe` (not a systemd boolean)"
            "last-wins.service: /var/lib/private/last-wins"
            "mixed-on.service: /var/lib/private/mixed-on"
            "reset.service: /var/lib/du-reset"
            "upper-off.service: /var/lib/upper-off"
            "upper-y.service: /var/lib/private/upper-y"
          ];
        };

        multiple-directories-string = {
          module = {
            systemd.services.multi = svc { StateDirectory = "multi-a multi-b:multi-link"; };
            preservation.preserveAt."/persist".directories = [ "/var/lib/multi-a" ];
          };
          fail = [ "multi.service: /var/lib/multi-b" ];
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
        };

        disposable-exemption-passes = {
          module = {
            systemd.services.scratch = svc { StateDirectory = "scratch"; };
            myAppStateAudit.exemptions.scratch = exemption "scratch.service" [
              "/var/lib/scratch"
            ] "disposable";
          };
        };

        pending-exemption-passes-and-warns = {
          module = {
            systemd.services.queue = svc {
              DynamicUser = true;
              StateDirectory = "queue";
            };
            myAppStateAudit.exemptions.queue = exemption "queue.service" [ "/var/lib/private/queue" ] "pending";
          };
          warn = [ (pendingWarning "queue.service" "/var/lib/private/queue" "queue") ];
        };

        conflicting-exemptions-fail = {
          module = {
            systemd.services.dup = svc { StateDirectory = "dup"; };
            myAppStateAudit.exemptions = {
              dup-a = exemption "dup.service" [ "/var/lib/dup" ] "disposable";
              dup-b = exemption "dup.service" [ "/var/lib/dup" ] "pending";
            };
          };
          fail = [ "dup.service: /var/lib/dup (exemptions.dup-a, exemptions.dup-b)" ];
          warn = [ (pendingWarning "dup.service" "/var/lib/dup" "dup-b") ];
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
            "ghost.service: /var/lib/ghost (exemptions.ghost)"
            "kept.service: /var/lib/kept (exemptions.kept)"
          ];
        };

        blank-reason-fails = {
          module = {
            systemd.services.blank = svc { StateDirectory = "blank"; };
            myAppStateAudit.exemptions.blank = exemption "blank.service" [ "/var/lib/blank" ] "disposable" // {
              reason = "  ";
            };
          };
          fail = [ "exemptions.blank" ];
        };

        disabled-unit-ignored = {
          module.systemd.services.off = svc { StateDirectory = "off"; } // {
            enable = false;
          };
        };

        no-preservation-no-audit = {
          module = {
            preservation.enable = false;
            systemd.services.omitted = svc { StateDirectory = "omitted"; };
          };
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
          gotLines = lib.sort lib.lessThan (
            map (lib.removePrefix "  ") (
              lib.filter (l: lib.hasPrefix "  " l) (lib.concatMap (lib.splitString "\n") failed)
            )
          );
          wantLines = lib.sort lib.lessThan (c.fail or [ ]);
          gotWarn = lib.sort lib.lessThan (lib.filter (lib.hasPrefix "myAppStateAudit") cfg.warnings);
          wantWarn = lib.sort lib.lessThan (c.warn or [ ]);
          show = ls: lib.concatMapStrings (l: "\n    ${l}") ls;
        in
        lib.optional (gotLines != wantLines) ''
          ${name}: failure lines differ
            want:${show wantLines}
            got:${show gotLines}
          --- audit output ---
          ${text}''
        ++ lib.optional (gotWarn != wantWarn) ''
          ${name}: warnings differ
            want:${show wantWarn}
            got:${show gotWarn}'';

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
