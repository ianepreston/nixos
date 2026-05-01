# OCI containers - Simple Aspect
# Podman backend for virtualisation.oci-containers. Backend-agnostic
# container declarations live in their own service modules.
_: {
  flake.modules.nixos.oci-containers = _: {
    virtualisation = {
      podman = {
        enable = true;
        dockerCompat = true;
        defaultNetwork.settings.dns_enabled = true;
      };
      oci-containers.backend = "podman";
    };

    # Containers on the default podman bridge reach host services
    # (postgres, etc.) via host.containers.internal -> 10.88.0.1.
    # Trust the bridge so the firewall doesn't drop those packets.
    networking.firewall.trustedInterfaces = [ "podman0" ];
  };
}
