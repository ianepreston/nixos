# IoT VLAN (vlan30) macvlan plumbing for podman containers.
#
# Shared infrastructure for any app container that needs L2 reachability
# on the IoT VLAN where the smart-home / 3D-printer devices live —
# currently Home Assistant (mDNS/SSDP discovery, broadcast) and Bambuddy
# (direct MQTT/FTP/camera to Bambu printers). Extracted out of
# homeassistant.nix once it grew a second consumer so neither app owns
# the other's networking.
#
# Topology (only stood up when hostSpec.iotTrunkInterface is non-null):
#   <hostSpec.iotTrunkInterface> ──┬── (untagged mgmt VLAN, host's primary IP)
#                                  └── iot (host VLAN sub-iface, no host IP)
#                                       └── macvlan children in each
#                                           consumer's netns (DHCP)
# The trunk NIC name varies per host (PCI-topology-dependent predictable
# names) so it's threaded through hostSpec; on hpp-1 it's enp1s0, on
# amos1 it's enp4s0. When the field is null (e.g. quickemu test VMs with
# no IoT VLAN) the whole stack is skipped and consumer containers fall
# back to the podman bridge only — discovery / printer access is lost,
# but the containers still start and stay probeable through Caddy.
#
# Caveat: macvlan children are L2-isolated from their parent host, so
# the host kernel can't talk to a container's vlan30 IP (only other
# vlan30 devices can). Non-issue for Caddy (consumers keep a second NIC
# on the default podman bridge for the web UI); revisit if a host-side
# service ever needs to probe a consumer on that interface.
#
# Consumers wire themselves to this stack by:
#   - attaching the `iot` macvlan: `networks = [ "podman" "iot" ]`
#   - ordering their container unit after it:
#       after/requires = [ "netavark-dhcp-proxy.service"
#                          "podman-network-iot.service" ]
# The `requires` edge is what pulls the network/proxy in, so this
# module deliberately declares no per-consumer `wantedBy`/`before`
# back-edges.
_: {
  flake.modules.nixos.iot-network =
    {
      hostSpec,
      lib,
      pkgs,
      ...
    }:
    let
      iotEnabled = hostSpec.iotTrunkInterface != null;
    in
    {
      config = lib.mkIf iotEnabled {
        networking = {
          # Tagged sub-interface for vlan30 on the host trunk. Host gets
          # no IP here — only the macvlan children do, via DHCP.
          vlans.iot = {
            id = 30;
            interface = hostSpec.iotTrunkInterface;
          };
          interfaces.iot.useDHCP = false;
          # NetworkManager would otherwise probe the trunk and fight us
          # for the netdev.
          networkmanager.unmanaged = [ "interface-name:iot" ];
        };

        systemd.services = {
          # netavark ships dhcp-proxy as a subcommand; no NixOS module
          # for it yet, so we run it directly. Listens on
          # /run/podman/nv-proxy.sock and brokers DHCP leases for
          # containers on macvlan networks with `--ipam-driver dhcp`.
          # netavark doesn't unlink the socket on shutdown, so a
          # restart (e.g. across `nixos-rebuild switch`) hits
          # EADDRINUSE and the unit crash-loops; ExecStartPre /
          # ExecStopPost clear it on both sides.
          netavark-dhcp-proxy = {
            description = "netavark DHCP proxy for podman macvlan IPAM";
            wantedBy = [ "multi-user.target" ];
            after = [ "network.target" ];
            serviceConfig = {
              Type = "simple";
              ExecStartPre = "-${pkgs.coreutils}/bin/rm -f /run/podman/nv-proxy.sock";
              ExecStart = "${pkgs.netavark}/bin/netavark dhcp-proxy";
              ExecStopPost = "-${pkgs.coreutils}/bin/rm -f /run/podman/nv-proxy.sock";
              Restart = "on-failure";
            };
          };

          # Idempotent oneshot: bring the iot sub-interface up and
          # create the macvlan podman network if it doesn't exist.
          # Parent is the `iot` netdev; children get DHCP via the proxy.
          podman-network-iot = {
            description = "podman macvlan network on vlan30";
            after = [
              "network-online.target"
              "podman.service"
              "sys-subsystem-net-devices-iot.device"
            ];
            wants = [ "network-online.target" ];
            bindsTo = [ "sys-subsystem-net-devices-iot.device" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            script = ''
              ${pkgs.iproute2}/bin/ip link set iot up
              if ! ${pkgs.podman}/bin/podman network exists iot; then
                ${pkgs.podman}/bin/podman network create \
                  --driver macvlan \
                  --opt parent=iot \
                  --ipam-driver dhcp \
                  iot
              fi
            '';
          };
        };
      };
    };
}
