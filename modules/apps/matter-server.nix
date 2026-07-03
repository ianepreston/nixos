# matter-server - WebSocket Matter/Thread bridge for Home Assistant
# Native services.matter-server from nixpkgs (DynamicUser + state at
# /var/lib/private/matter-server). No web UI, no OIDC — it's a
# WebSocket that HA's matter integration connects to as a client.
#
# Network reach: matter-server runs on the host network and binds the
# WebSocket on `0.0.0.0:5580`. HA reaches it via the podman bridge
# gateway at `ws://10.88.0.1:5580/ws` (HA has the default bridge NIC
# alongside its vlan30 macvlan child — see modules/apps/homeassistant.nix).
# The host firewall blocks 5580 on every external NIC; podman0 is in
# trustedInterfaces (see oci-containers.nix), so this surface is only
# loopback + the bridge in practice.
#
# Operator setup after first deploy: in HA, Configuration → Devices &
# Services → Add Integration → Matter (BETA), URL
# `ws://10.88.0.1:5580/ws`. No password — HA is the only consumer and
# the port surface is loopback + podman bridge in practice.
#
# Multicast caveat: real Matter device commissioning needs IPv6 mDNS
# reach on the IoT VLAN. The host has no IP on the `iot` netdev (only
# HA's macvlan child does), so the matter-server process can't
# currently see vlan30 multicast traffic. The service still comes up
# clean without devices, and the HA integration connects via the
# WebSocket — but actual Matter-over-IP commissioning will need
# follow-up work (either an IP on the `iot` netdev or running
# matter-server in a netns with macvlan reach). Deferred until Matter
# hardware is on hand.
_: {
  flake.modules.nixos.matter-server = _: {
    services.matter-server = {
      enable = true;
    };

    # DynamicUser puts state under /var/lib/private/<service>; the public
    # /var/lib/matter-server is a symlink. Preserve the actual storage
    # path (same pattern as authentik). user/group left null so the
    # preservation entry omits them (DynamicUser manages ownership).
    myAppState.matter-server = {
      stateDir = "/var/lib/private/matter-server";
      user = null;
      group = null;
    };
  };
}
