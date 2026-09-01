# llm-terra - HTTPS + SSO front door for terra's llama-server
#
# Route only. No service, no state, no database: terra runs the actual
# llama-server (see modules/system/llama-cpp.nix and modules/hosts/terra.nix)
# and this is the reverse-proxy entry that gives it TLS and authentik
# without replicating caddy/authentik/tailscale onto a workstation.
# Nothing here to back up, hence no `recovery:` dispatcher — the restore
# story for this module is "rebuild the host".
#
# Imported by both servers, so the same backend is reachable as
# llm-terra.dnix.ipreston.net (hpp-1, dev) and llm-terra.amos.ipreston.net
# (amos1, prod). terra's firewall allowlist names both.
#
# Address: `terra.ipreston.net` is registered by the router from terra's
# DHCP lease, so terra needs a DHCP reservation for the route to stay
# pointed at the right machine. terra is a desktop that gets powered off,
# and this route 502s while it is down — that's expected, not a fault.
#
# Backend hop is plaintext HTTP over the LAN. That is a deliberate call:
# the only thing crossing it is prompt/completion traffic and terra's
# own `--api-key` bearer token, between two machines on the same trusted
# wired segment, and the alternative (a self-signed cert on terra plus
# `reverse_proxy https://` with a trust override) buys little against a
# threat model where an attacker already has the LAN.
#
# ## Why /v1/* bypasses forward-auth, and why the bypass is conditional
#
# OpenAI-compatible clients send a bearer token; they cannot follow an
# authentik login redirect. So the API paths skip forward_auth and are
# gated instead by llama-server's own `--api-key`.
#
# Path alone isn't the right condition, though. llama-server enforces its
# key on nearly everything it serves — `/props` and `/slots` as well as
# `/v1/chat/completions` — and only `/`, `/index.html` and the bundles are
# public. So the web UI loads, then its own XHRs 401, and it prompts the
# human for a shared API key they have just earned by logging into
# authentik. Gating on SSO and then demanding the shared secret anyway
# defeats the point of the SSO.
#
# Hence `upstreamBearerEnvVar`: the bypass additionally requires an
# `Authorization` header, so it catches API clients and not browsers, and
# the authentik-gated branch injects the key upstream itself. A browser
# logs into authentik and simply works; an API client presents its own
# token as before.
#
# That also closes a leak this route used to accept. llama-server treats
# `/v1/models` and `/v1/health` as public — served with no key even when
# `--api-key` is set — so a plain path bypass exposed the model list
# unauthenticated on these hostnames. With the header condition, an
# unauthenticated request to `/v1/*` lands on authentik instead of
# reaching llama-server at all.
{ inputs, ... }:
{
  flake.modules.nixos.llm-terra =
    { config, ... }:
    {
      myAuthentik.forwardAuthApps.llm-terra = {
        upstreamHost = "terra.ipreston.net";
        port = 8080;
        displayName = "LLM (terra)";
        # dashboard-icons has no llama.cpp entry; ollama is the closest
        # local-inference icon in the set.
        iconUrl = "https://raw.githubusercontent.com/homarr-labs/dashboard-icons/main/png/ollama.png";
        bypassAuthPaths = [ "/v1/*" ];
        upstreamBearerEnvVar = "LLAMA_API_KEY";
        homepage = {
          group = "Infrastructure";
          icon = "ollama";
          description = "Local inference on terra";
        };
      };

      # Same key terra's llama-server enforces, so it lives in shared.yaml
      # rather than either host's file — see modules/system/llama-cpp.nix.
      sops.secrets."llama-cpp/api_key" = {
        sopsFile = "${inputs.nix-secrets}/sops/shared.yaml";
      };

      # Stacked as a second EnvironmentFile rather than merged into
      # caddy.nix's own template: this key belongs to one app, and
      # `EnvironmentFile` is a list, so an app module can contribute one
      # without caddy.nix growing an option surface for it.
      # restartUnits goes on the template only (see CLAUDE.md) — sops-nix
      # re-renders it whenever the underlying secret rotates.
      sops.templates."llm-terra-caddy.env" = {
        content = ''
          LLAMA_API_KEY=${config.sops.placeholder."llama-cpp/api_key"}
        '';
        owner = "caddy";
        restartUnits = [ "caddy.service" ];
      };

      systemd.services.caddy.serviceConfig.EnvironmentFile = [
        config.sops.templates."llm-terra-caddy.env".path
      ];
    };
}
