# Local service endpoint contracts.
#
# A producer publishes only the connection details local consumers may rely on:
# its URL and the systemd unit that must be ready first. This keeps consumers
# from depending on an application's implementation details (container shape,
# upstream option names, or private port settings) while leaving the producer
# free to change them.
#
# A host process and a container on the podman bridge reach a host service by
# different names: inside a container's network namespace, loopback is the
# container itself. So the contract carries two URLs. `url` is for host
# processes; `containerUrl` is published only by a producer that actually
# listens on the bridge, and is the one a container consumer must use. It
# stays null otherwise, and the assertion below refuses a loopback
# `containerUrl`, so a loopback address is never handed unchanged to a
# container.
_: {
  flake.modules.nixos.service-endpoints =
    { config, lib, ... }:
    let
      # Loopback and wildcard hosts all name the container itself.
      loopbackHost =
        host:
        lib.elem host [
          "localhost"
          "0.0.0.0"
          "[::1]"
          "[::]"
        ]
        || lib.hasSuffix ".localhost" host
        || builtins.match "127\\.[0-9.]+" host != null;
      # The authority's host (an IPv6 literal keeps its brackets), or null
      # when the value is not an absolute URL.
      urlHost =
        url:
        let
          m = builtins.match "[a-z][a-z0-9+.-]*://(\\[[^]]*]|[^]/:?#[]+).*" (lib.toLower url);
        in
        if m == null then null else lib.head m;
    in
    {
      options.myServiceEndpoints = lib.mkOption {
        default = { };
        description = ''
          Locally consumable service endpoints. A producing module declares a
          URL and its readiness unit; a consuming module uses that contract
          instead of reading the producer's implementation configuration.
        '';
        type = lib.types.attrsOf (
          lib.types.submodule (
            { name, ... }:
            {
              options = {
                url = lib.mkOption {
                  type = lib.types.str;
                  description = "URL local host processes use to reach the ${name} service.";
                };
                containerUrl = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = ''
                    URL a container on the default podman bridge uses to reach
                    the ${name} service, normally via
                    `host.containers.internal`. Set only by a producer that
                    listens on the bridge; null means containers cannot reach
                    it. Never a loopback address.
                  '';
                  example = "http://host.containers.internal:8080";
                };
                unit = lib.mkOption {
                  type = lib.types.str;
                  description = "Systemd unit local consumers order after before reaching ${name}.";
                  example = "example.service";
                };
              };
            }
          )
        );
      };

      config.assertions = lib.concatLists (
        lib.mapAttrsToList (
          name: endpoint:
          let
            host = urlHost endpoint.containerUrl;
          in
          lib.optional (endpoint.containerUrl != null) {
            assertion = host != null && !(loopbackHost host);
            message = "myServiceEndpoints.${name}.containerUrl: `${endpoint.containerUrl}` must be an absolute URL whose host a container can reach (normally host.containers.internal); a loopback or wildcard host names the container itself.";
          }
        ) config.myServiceEndpoints
      );
    };
}
