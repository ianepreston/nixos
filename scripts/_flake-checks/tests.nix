# Unit cases for derivations.nix and toplevel.nix (#1021). Each case runs the
# expression on a synthetic value under builtins.tryEval, so a rejection
# (`throw`) is `false` and an acceptance is `true`; the flake check compares
# `actual` with `expected` at build time. Inputs only ever fail by `throw`, so
# a case can never break evaluation of the flake itself.
{
  derivations ? import ./derivations.nix,
  toplevel ? import ./toplevel.nix,
  system,
}:
let
  ok = v: (builtins.tryEval (builtins.deepSeq v true)).success;
  mk =
    name: sys:
    derivation {
      inherit name;
      system = sys;
      builder = "/bin/sh";
    };
  real = mk "flake-checks-real" system;
  foreign = mk "flake-checks-foreign" "riscv64-linux";
  args = {
    inherit system;
    single = false;
    label = "t";
  };
  fake = attrs: { type = "derivation"; } // attrs;
  sysSet = v: { ${system} = v; };

  cases = {
    real-derivation = ok (derivations args { a = real; });
    bogus-drvpath = ok (
      derivations args {
        a = fake {
          inherit system;
          drvPath = "bogus";
        };
      }
    );
    contextless-store-drvpath = ok (
      derivations args {
        a = fake {
          inherit system;
          drvPath = builtins.unsafeDiscardStringContext real.drvPath;
        };
      }
    );
    missing-drvpath = ok (derivations args { a = fake { inherit system; }; });
    not-a-derivation = ok (derivations args { a = { inherit (real) drvPath system; }; });
    system-mismatch = ok (derivations args { a = foreign; });
    single-derivation = ok (derivations (args // { single = true; }) real);
    derivation-where-set-expected = ok (derivations args real);
    null-system-skips-system-check = ok (
      derivations (
        args
        // {
          system = null;
          single = true;
        }
      ) foreign
    );

    toplevel-well-formed = ok (toplevel {
      checks = sysSet { };
      packages = sysSet { };
      legacyPackages = sysSet { coding-sandbox = { }; };
      formatter = { };
      overlays.o = _final: _prev: { };
      nixosModules.m = _: { };
      apps = sysSet {
        a = {
          type = "app";
          program = "/bin/sh";
        };
      };
      lib = { };
    });
    toplevel-throwing-output = ok (toplevel {
      checks = { };
      lib = throw "boom";
    });
    toplevel-invalid-system-name = ok (toplevel {
      checks.linux = { };
    });
    toplevel-legacy-packages-undeclared-system = ok (toplevel {
      checks = sysSet { };
      legacyPackages.riscv64-linux = { };
    });
    toplevel-legacy-packages-invalid-system = ok (toplevel {
      checks = sysSet { };
      legacyPackages.coding-sandbox = { };
    });
    toplevel-one-argument-overlay = ok (toplevel {
      overlays.o = _final: { };
    });
    toplevel-formals-overlay = ok (toplevel {
      overlays.o = { pkgs }: _prev: pkgs;
    });
    toplevel-attrset-overlay = ok (toplevel {
      overlays.o = { };
    });
    toplevel-invalid-module = ok (toplevel {
      nixosModules.m = 3;
    });
    toplevel-invalid-app = ok (toplevel {
      checks = sysSet { };
      apps = sysSet { a.type = "derivation"; };
    });
  };
in
{
  actual = cases;
  expected = builtins.mapAttrs (_: _: false) cases // {
    real-derivation = true;
    single-derivation = true;
    null-system-skips-system-check = true;
    toplevel-well-formed = true;
  };
}
