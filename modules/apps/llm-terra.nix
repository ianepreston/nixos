# llm-terra - HTTPS + SSO front door for terra's llama-server
#
# Route only. No service, no state, no database: terra runs the actual
# llama-server (see modules/system/llama-cpp.nix and modules/hosts/terra.nix)
# and this is the reverse-proxy entry that gives it TLS and authentik
# without replicating caddy/authentik/tailscale onto a workstation.
# Nothing here to back up, hence no `recovery:` dispatcher — the restore
# story for this module is "rebuild the host".
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
# ## Why /v1/* bypasses forward-auth
#
# OpenAI-compatible clients send a bearer token; they cannot follow an
# authentik login redirect. So the API paths skip forward_auth and are
# gated instead by llama-server's own `--api-key` (fed from sops on
# terra) — the same "the app has its own key auth on this sub-path"
# pattern as radarr's /api/*. The browser UI at `/` stays gated.
#
# Caveat worth knowing: llama-server treats `/v1/models` and `/v1/health`
# as public endpoints and serves them with no key even when `--api-key`
# is set. Bypassing `/v1/*` therefore exposes the model list on this
# hostname unauthenticated. `*.amos.ipreston.net` has no public DNS
# record and no inbound port-forward — it resolves only on the LAN and
# over tailscale — so the exposure is "someone already inside can see
# which model is loaded", which is acceptable. Do not add a public
# ingress for this hostname without revisiting it.
_: {
  flake.modules.nixos.llm-terra = _: {
    myAuthentik.forwardAuthApps.llm-terra = {
      upstreamHost = "terra.ipreston.net";
      port = 8080;
      displayName = "LLM (terra)";
      # dashboard-icons has no llama.cpp entry; ollama is the closest
      # local-inference icon in the set.
      iconUrl = "https://raw.githubusercontent.com/homarr-labs/dashboard-icons/main/png/ollama.png";
      bypassAuthPaths = [ "/v1/*" ];
      homepage = {
        group = "Infrastructure";
        icon = "ollama";
        description = "Local inference on terra";
      };
    };
  };
}
