# Standalone tools run by hand rather than installed on any host.
#
# thermal-bench (scripts/thermal-bench.sh, #757) — reproducible CPU/GPU
# thermal capture for before/after hardware changes. A flake package rather
# than a NixOS module on purpose: a one-off measurement shouldn't need a
# rebuild of prod, and a CUDA gpu-burn has no business in a system closure.
# Run it with `task thermal:bench` from a checkout, or
# `nix run github:ianepreston/nixos#thermal-bench` on a host without one.
{ inputs, self, ... }:
{
  perSystem =
    { pkgs, lib, ... }:
    let
      # gpu-burn is `broken = !cudaSupport`, and this flake's nixpkgs has
      # CUDA off, so it needs its own instance. Deliberately not shared with
      # modules/system/llama-cpp.nix's: that one pins cudaCapabilities per
      # host from `myLlamaCpp`, and a perSystem package has no host to ask.
      # Both fleet cards are hardcoded instead — amos1's RTX 3070 (8.6) and
      # terra's RTX 5080 (12.0) — so one store path serves both hosts and
      # the build compiles two architectures rather than the default nine.
      #
      # CUDA is unfree and no binary cache serves it: the first build is
      # local and slow. The heavy CUDA inputs are shared with the llama-cpp
      # build already in both hosts' stores.
      pkgsCuda = import inputs.nixpkgs {
        inherit (pkgs.stdenv.hostPlatform) system;
        config = {
          allowUnfree = true;
          cudaSupport = true;
          cudaCapabilities = [
            "8.6"
            "12.0"
          ];
        };
      };
    in
    {
      # stress-ng and gpu-burn are Linux-only, and `task check` evaluates the
      # Darwin systems too. Gate the contents, not the attribute (see
      # checks-rollback-root.nix).
      packages = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        thermal-bench = pkgs.writeShellApplication {
          name = "thermal-bench";
          # nvidia-smi is deliberately absent: it has to match the running
          # kernel driver, so it comes from the host's PATH.
          runtimeInputs = [
            pkgs.stress-ng
            pkgsCuda.gpu-burn
            pkgs.jq
            pkgs.coreutils
            pkgs.gnused
            pkgs.gnugrep
            pkgs.util-linux # setsid
            pkgs.hostname
            pkgs.getent
          ];
          runtimeEnv.THERMAL_BENCH_REV = self.shortRev or self.dirtyShortRev or "unknown";
          text = builtins.readFile ../../scripts/thermal-bench.sh;
        };
      };
    };
}
