# IoT VLAN (vlan30) plumbing: the host's tagged sub-interface, the
# firewall gate that keeps that segment untrusted, and the static
# macvlan bambuddy's Virtual Printer rides.
#
# The smart-home devices and 3D printers live on vlan30, jailed off the
# rest of the network by pfSense. Two things on these servers need to be
# on that segment at L2: Home Assistant (mDNS/SSDP discovery, and Matter
# over IPv6 link-local via matter-server) and bambuddy's Virtual Printer
# (direct MQTT/FTP/camera to Bambu printers).
#
# Topology (only stood up when hostSpec.iotTrunkInterface is non-null):
#   <hostSpec.iotTrunkInterface> ──┬── (untagged mgmt VLAN, host's primary IP)
#                                  └── iot (host VLAN sub-iface)
#                                       ├── the host itself, DHCP lease —
#                                       │   claimed by modules/apps/homeassistant.nix,
#                                       │   which mkForces useDHCP back on. HA and
#                                       │   matter-server run natively, in the host
#                                       │   netns, so this is their only path onto
#                                       │   vlan30.
#                                       └── iot-static: podman macvlan for
#                                           bambuddy's VP (host-local IPAM,
#                                           only when hostSpec.bambuddyVpIp is set)
# The trunk NIC name varies per host (PCI-topology-dependent predictable
# names) so it's threaded through hostSpec; on hpp-1 it's enp1s0, on
# amos1 it's enp4s0. When the field is null (e.g. quickemu test VMs with
# no IoT VLAN) the whole stack is skipped — discovery / printer access is
# lost, but everything still starts and stays probeable through Caddy.
#
# History: this module used to also run a DHCP-IPAM macvlan network
# (`iot`) plus netavark's dhcp-proxy, for containers that needed a vlan30
# child interface. Home Assistant was the only DHCP consumer and it went
# native in #430; bambuddy uses static IPAM. Both units were removed in
# #476 — the proxy was self-exiting ("timeout met: exiting after 300 secs
# of inactivity") on every boot with nothing to serve.
#
# Caveat: macvlan children are L2-isolated from their parent host, so the
# host kernel can't talk to a container's vlan30 IP (only other vlan30
# devices can). Non-issue for Caddy (consumers keep a second NIC on the
# default podman bridge for the web UI); revisit if a host-side service
# ever needs to probe a consumer on that interface.
_: {
  flake.modules.nixos.iot-network =
    {
      config,
      hostSpec,
      lib,
      pkgs,
      ...
    }:
    let
      iotEnabled = hostSpec.iotTrunkInterface != null;
      # vlan30 (IoT VLAN) + mgmt VLAN addressing — fixed for this homelab,
      # used only for bambuddy's static VP macvlan.
      # mgmtSubnet is where the slicers live; the VP macvlan needs an explicit
      # return route to it via the vlan30 gateway (see the network below).
      iotSubnet = "192.168.30.0/24";
      iotGateway = "192.168.30.1";
      mgmtSubnet = "192.168.10.0/24";
    in
    {
      config = lib.mkIf iotEnabled {
        networking = {
          # Tagged sub-interface for vlan30 on the host trunk.
          vlans.iot = {
            id = 30;
            interface = hostSpec.iotTrunkInterface;
          };
          # Default off; homeassistant.nix mkForces it on where HA runs.
          interfaces.iot.useDHCP = false;
          # NetworkManager would otherwise probe the trunk and fight us
          # for the netdev.
          networkmanager.unmanaged = [ "interface-name:iot" ];

          # vlan30 is an untrusted segment and must stay that way, but the
          # NixOS firewall's allowlist is global, not per-interface: every
          # `allowedTCPPorts` entry becomes an accept rule with no `-i`
          # match, so once the host holds a lease here the *whole* server
          # allowlist (22/80/443 + the UniFi ports) answers on vlan30. That
          # hands a compromised IoT device hypervisor SSH and the UniFi
          # controller admin UI on the same broadcast domain, bypassing the
          # pfSense jail entirely (#476).
          #
          # `networking.firewall.interfaces.iot.*` does not fix this — a
          # per-interface attrset only ever *adds* accepts, it can't subtract
          # the global ones. Scoping the globals the other way (moving every
          # port onto a named LAN interface) would mean threading enp1s0 /
          # enp4s0 through every module that opens a port, and getting it
          # wrong locks the host out. So: deny-list the one untrusted
          # interface, at the head of nixos-fw, before any accept can match.
          # Interface-name-agnostic, and it fails safe.
          #
          # Deliberately *not* opened here: mDNS 5353 and SSDP 1900. Inbound
          # multicast is already refused host-wide today (nixos-fw-log-refuse
          # starts with `-m pkttype ! --pkt-type unicast -j nixos-fw-refuse`),
          # so discovery runs on unicast responses matched by conntrack. This
          # gate only denies traffic that is accepted today, which makes it
          # parity-by-construction for HA; opening those ports would be new
          # exposure, not a restoration.
          firewall.extraCommands = ''
            ip46tables -N nixos-fw-iot 2>/dev/null || ip46tables -F nixos-fw-iot

            # Replies to sessions the host started stay allowed — HA and
            # matter-server reach out to devices and need the answers back.
            ip46tables -A nixos-fw-iot -m conntrack --ctstate RELATED,ESTABLISHED -j nixos-fw-accept
          ''
          + lib.optionalString config.networking.enableIPv6 ''

            # ICMPv6 is not optional on a link — ND/RA/PMTU all ride it, and
            # Matter is IPv6-native (matter-server talks to devices over
            # link-local), so refusing it would black-hole Matter. Mirror the
            # global v6 policy rather than inventing one.
            ip6tables -A nixos-fw-iot -p ipv6-icmp -m icmp6 --icmpv6-type 137 -j DROP
            ip6tables -A nixos-fw-iot -p ipv6-icmp -m icmp6 --icmpv6-type 139 -j DROP
            ip6tables -A nixos-fw-iot -p ipv6-icmp -j nixos-fw-accept
            ip6tables -A nixos-fw-iot -d fe80::/64 -p udp -m udp --dport 546 -j nixos-fw-accept
          ''
          + ''

            ip46tables -A nixos-fw-iot -j nixos-fw-log-refuse

            # nixos-fw is flushed on every start/reload, so this is the first
            # rule in it and no dedup is needed.
            ip46tables -I nixos-fw 1 -i iot -j nixos-fw-iot

            # Same defect on the routing path: podman turns on ip_forward and
            # FORWARD's policy is ACCEPT, so a vlan30 device could name us as
            # its next hop and route straight into the mgmt VLAN. Nothing
            # legitimately routes *out of* vlan30 through this host — the
            # macvlan children are L2-attached and never traverse FORWARD. We
            # own FORWARD rules directly (no chain the firewall flushes for
            # us), so delete-then-insert to stay idempotent across reloads.
            # ND/RA are link-local and never forwarded, so no ICMPv6 carve-out
            # here. Only `-i iot` is gated: the host and its containers may
            # still initiate *into* vlan30, and the conntrack rule lets those
            # replies home.
            ip46tables -D FORWARD -i iot -m conntrack --ctstate RELATED,ESTABLISHED -j nixos-fw-accept 2>/dev/null || true
            ip46tables -D FORWARD -i iot -j nixos-fw-log-refuse 2>/dev/null || true
            ip46tables -I FORWARD 1 -i iot -m conntrack --ctstate RELATED,ESTABLISHED -j nixos-fw-accept
            ip46tables -I FORWARD 2 -i iot -j nixos-fw-log-refuse
          '';

          firewall.extraStopCommands = ''
            ip46tables -D FORWARD -i iot -j nixos-fw-log-refuse 2>/dev/null || true
            ip46tables -D FORWARD -i iot -m conntrack --ctstate RELATED,ESTABLISHED -j nixos-fw-accept 2>/dev/null || true
            ip46tables -D nixos-fw -i iot -j nixos-fw-iot 2>/dev/null || true
            ip46tables -F nixos-fw-iot 2>/dev/null || true
            ip46tables -X nixos-fw-iot 2>/dev/null || true
          '';
        };

        # Static macvlan for bambuddy's Virtual Printer. The VP needs a
        # fixed, dedicated vlan30 IP, but DHCP reservations aren't honored
        # here (netavark's DHCP client sends a client-id the router matches
        # on instead of the MAC), so bambuddy rides this host-local (static)
        # IPAM network on the same vlan30 parent and requests a specific
        # --ip. We add an explicit --route to the slicer (mgmt) subnet via
        # the vlan30 gateway rather than a --gateway default: a macvlan
        # default would compete with the podman-bridge default (both metric
        # 100), and the kernel's nondeterministic tie-break can send replies
        # out the bridge (NAT'd, wrong source), making the VP unreachable.
        # The specific route always wins for slicer traffic. Only stood up
        # on hosts that pin a bambuddy VP IP (hostSpec.bambuddyVpIp).
        #
        # No `wantedBy`: bambuddy's `requires` edge is what pulls this in,
        # so hosts with the code but no bambuddy don't create the network.
        systemd.services = lib.mkIf (hostSpec.bambuddyVpIp != null) {
          podman-network-iot-static = {
            description = "podman static macvlan on vlan30 (bambuddy VP)";
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
              if ! ${pkgs.podman}/bin/podman network exists iot-static; then
                ${pkgs.podman}/bin/podman network create \
                  --driver macvlan \
                  --opt parent=iot \
                  --subnet ${iotSubnet} \
                  --route ${mgmtSubnet},${iotGateway} \
                  iot-static
              fi
            '';
          };
        };
      };
    };
}
