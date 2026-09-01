# llm-caddy-auth - hands caddy the llama-server bearer token
#
# Shared by both llama-server routes (modules/apps/llm.nix for the local
# instance, modules/apps/llm-terra.nix for terra's). Both set
# `upstreamBearerEnvVar = "LLAMA_API_KEY"`, so both need the same variable
# in caddy's environment — and amos1 imports both at once, which is why
# this can't just live in one of them.
#
# One key covers both instances: `myLlamaCpp` reads `llama-cpp/api_key`
# from shared.yaml wherever it runs, so terra's llama-server and amos1's
# enforce the same token and caddy injects the same value for either
# route. Worth knowing before assuming the two endpoints are isolated —
# a client holding the key can reach both.
#
# Stacked as a second EnvironmentFile rather than merged into caddy.nix's
# own template: this belongs to the llm modules, and `EnvironmentFile` is
# a list, so an app can contribute one without caddy.nix growing an
# option surface for it. restartUnits goes on the template only (see
# CLAUDE.md) — sops-nix re-renders it whenever the secret rotates.
{ inputs, ... }:
{
  # `key` makes the module system dedupe this when both llm.nix and
  # llm-terra.nix import it on the same host. Without it each import is
  # treated as a distinct module and caddy ends up with the same
  # EnvironmentFile listed twice — harmless, but noise in the unit.
  flake.modules.nixos.llm-caddy-auth = {
    key = "llm-caddy-auth";
    imports = [
      (
        { config, ... }:
        {
          sops.secrets."llama-cpp/api_key" = {
            sopsFile = "${inputs.nix-secrets}/sops/shared.yaml";
          };

          sops.templates."llm-caddy.env" = {
            content = ''
              LLAMA_API_KEY=${config.sops.placeholder."llama-cpp/api_key"}
            '';
            owner = "caddy";
            restartUnits = [ "caddy.service" ];
          };

          systemd.services.caddy.serviceConfig.EnvironmentFile = [
            config.sops.templates."llm-caddy.env".path
          ];
        }
      )
    ];
  };
}
