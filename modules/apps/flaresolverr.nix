# FlareSolverr - proxy that solves Cloudflare/DDoS-GUARD challenges so
# indexers can be scraped. Consumed internally by the *arr stack
# (prowlarr) and shelfarr, which need it for indexers behind Cloudflare.
#
# Native services.flaresolverr from nixpkgs (3.5.x). Stateless — the
# upstream service keeps no on-disk state (HOME is a RuntimeDirectory),
# so like decluttarr it has no preservation entry, no backup path, and
# no recovery task.
#
# Internal-only: listens on :8191 with the firewall left closed. Native
# consumers reach it at http://localhost:8191; podman containers
# (shelfarr) reach it at http://host.containers.internal:8191 over the
# already-trusted podman bridge — flaresolverr binds 0.0.0.0 by default,
# so both paths work without opening the port externally.
_: {
  flake.modules.nixos.flaresolverr = {
    services.flaresolverr.enable = true;
  };
}
