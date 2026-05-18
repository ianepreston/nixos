# tests-server - quickemu VM used as the sacrificial target for the
# quarterly `task recovery:test:full` drill. Mirrors hpp-1's
# environment ("dev") and serverDomain so OIDC client IDs and other
# domain-embedded values in the restored snapshot still line up. The
# sopsFile override points at hpp-1.yaml so this host decrypts the same
# secret bundle hpp-1 uses at runtime — without that, restored
# postgres roles wouldn't match the passwords mealie/miniflux/etc.
# expect at boot. tests-server's age key must be present in
# hpp-1.yaml's creation rule in nix-secrets/.sops.yaml for this to
# decrypt — see taskfiles/recovery.yaml's tests-server:sops-authorize
# for the one-time setup the operator runs.
{ inputs, ... }:
{
  config.hostSpecs.tests-server = {
    hostName = "tests-server";
    isMinimal = false;
    serverEnvironment = "dev";
    serverDomain = "dnix.ipreston.net";
    # Placeholder — the VM lives behind quickemu user-mode NAT and
    # nothing in the drill exercises serverLanIp directly.
    serverLanIp = "127.0.0.1";
    sopsFile = "${inputs.nix-secrets}/sops/hpp-1.yaml";
    inherit (inputs.nix-secrets) email;
  };
}
