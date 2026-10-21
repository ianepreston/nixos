# ACB — adjusted cost-base calculator for Canadian tax filing
# (https://github.com/tsiemens/acb, MIT). Upstream ships a Vue UI over a
# WebAssembly Rust core, with no server component: transactions and generated
# files remain in the browser. Caddy therefore serves a Nix-built static site;
# there is no state, database, secret, container, recovery record, or service
# unit to declare.
_:
let
  acbPackages = import ./_acb/package.nix;
in
{
  perSystem =
    { pkgs, ... }:
    {
      packages = acbPackages { inherit pkgs; };
    };

  flake.modules.nixos.acb =
    {
      hostSpec,
      pkgs,
      ...
    }:
    let
      acbWeb = (acbPackages { inherit pkgs; }).acb-web;
      acbHost = "acb.${hostSpec.serverDomain}";
      iconUrl = "https://raw.githubusercontent.com/tsiemens/acb/v0.26.04.2/www/static/images/acb_logo.svg";
    in
    {
      myAuthentik.forwardAuthApps.acb = {
        host = acbHost;
        displayName = "ACB";
        staticRouteConfig = ''
          encode zstd gzip
          root * ${acbWeb}
          try_files {path} {path}/ /index.html
          file_server
        '';
        homepage = {
          group = "Home";
          icon = iconUrl;
          description = "Canadian adjusted cost-base calculator";
        };
      };
    };
}
