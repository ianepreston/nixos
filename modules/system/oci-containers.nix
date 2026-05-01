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
  };
}
