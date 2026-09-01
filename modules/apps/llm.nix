# llm - HTTPS + SSO front door for this host's own llama-server
#
# The server-side half of local inference: the daemon itself comes from
# modules/system/llama-cpp.nix (`myLlamaCpp`), which a host enables and
# sizes for its own GPU. This module is what makes it reachable —
# the authentik application, the caddy route, the homepage tile, and the
# preservation entry for the model cache.
#
# Sibling of modules/apps/llm-terra.nix, which is the same idea pointed at
# terra instead of localhost. A server can carry both; amos1 does, so
# `llm.<serverDomain>` is the always-on instance and
# `llm-terra.<serverDomain>` is terra's larger model when that desktop
# happens to be powered on.
#
# The upstream port is read from `myLlamaCpp.port` rather than repeated,
# because it genuinely varies per host — 8080 is taken by unifi-os-server
# on amos1, so the daemon there listens elsewhere.
#
# ## Model cache under impermanence
#
# llama-server downloads GGUFs into its StateDirectory, which on an
# impermanence host is wiped on reboot unless preserved. Several GB of
# re-download on every boot is worth avoiding, so there's a preservation
# entry below.
#
# It is deliberately **not** a `myAppState` app. `myAppState` derives the
# preservation entry *and* a restic path from one declaration, and a GGUF
# has no business in a nightly snapshot: it's a few gigabytes of bytes
# that huggingface will hand back on demand, not state anyone authored.
# Same reasoning as sabnzbd's incomplete dir — preserve-only, listed in
# `residualPreservedDirs` in modules/profiles/server-apps.nix so the
# structural guard still asserts it stays preserved.
#
# That also means no `recovery:` dispatcher: there is nothing in restic to
# restore. After a catastrophic rebuild the model re-downloads on first
# start, which is the correct behaviour, just slow.
#
# Why /v1/* bypasses forward-auth conditionally, and why caddy injects the
# bearer token, is documented in modules/apps/llm-terra.nix — the same
# reasoning applies here and isn't repeated.
{ inputs, ... }:
{
  flake.modules.nixos.llm =
    { config, ... }:
    {
      imports = [ inputs.self.modules.nixos.llm-caddy-auth ];

      myAuthentik.forwardAuthApps.llm = {
        inherit (config.myLlamaCpp) port;
        displayName = "LLM";
        # dashboard-icons has no llama.cpp entry; ollama is the closest
        # local-inference icon in the set.
        iconUrl = "https://raw.githubusercontent.com/homarr-labs/dashboard-icons/main/png/ollama.png";
        bypassAuthPaths = [ "/v1/*" ];
        upstreamBearerEnvVar = "LLAMA_API_KEY";
        homepage = {
          group = "Infrastructure";
          icon = "ollama";
          description = "Always-on local inference";
        };
      };

      # DynamicUser + StateDirectory, so the real storage is the private
      # path — same shape as authentik's entry, and a bare string for the
      # same reason: ownership is systemd's to manage, not ours.
      #
      # A preservation bindmount hands the unit a root:root 0700 directory
      # on a fresh boot, which looks alarming for a DynamicUser service.
      # It isn't: systemd chowns an existing StateDirectory to the on-disk
      # sentinel (nobody:nogroup 0755) before ExecStart and the unit writes
      # through the idmapped mount normally. Verified directly with a
      # throwaway DynamicUser unit against a pre-created root:root 0700
      # dir. No ExecStartPre chown is needed here — authentik's is healing
      # a different hazard (stale files literally owned by the dynamic uid,
      # written before idmapped mounts existed).
      preservation.preserveAt."/persist".directories = [ "/var/lib/private/llama-cpp" ];
    };
}
