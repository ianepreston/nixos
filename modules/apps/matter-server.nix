# matter-server - WebSocket Matter/Thread bridge for Home Assistant
# Native services.matter-server from nixpkgs (DynamicUser + state at
# /var/lib/private/matter-server). No web UI, no OIDC — it's a
# WebSocket that HA's matter integration connects to as a client.
#
# Native Home Assistant and matter-server share the host network namespace,
# so HA connects to the WebSocket over IPv4 loopback. The matter-server
# module leaves its firewall port closed by default.
#
# Operator setup after first deploy: add the Matter integration in HA and
# enter `ws://127.0.0.1:5580/ws`.
#
# Matter commissioning on vlan30 needs IPv6 mDNS discovery. When an IoT
# trunk is configured, homeassistant.nix uses mkForce to set
# networking.interfaces.iot.useDHCP = true on the host. The firewall gate
# in iot-network.nix allows replies to host-initiated traffic and blocks
# inbound multicast mDNS (UDP 5353) on `iot`. Revisit the gate and test
# commissioning when Matter hardware is available.
_: {
  flake.modules.nixos.matter-server = _: {
    myObservability.monitoredSystemdUnits = [ "matter-server" ];

    myRecovery.apps.matter-server = {
      kind = "volume";
      order = 130;
      units = [ "matter-server.service" ];
      paths = [ "/var/lib/private/matter-server" ];
    };

    services.matter-server = {
      enable = true;
    };

    # DynamicUser puts state under /var/lib/private/<service>; the public
    # /var/lib/matter-server is a symlink. Preserve the actual storage
    # path (same pattern as authentik). dynamicUser makes the preservation
    # entry match systemd's on-disk owner rather than resetting it (#949).
    myAppState.matter-server = {
      stateDir = "/var/lib/private/matter-server";
      dynamicUser = true;
    };
  };
}
