# Local service endpoint contracts.
#
# A producer publishes only the connection details local consumers may rely on:
# its URL and the systemd unit that must be ready first. This keeps consumers
# from depending on an application's implementation details (container shape,
# upstream option names, or private port settings) while leaving the producer
# free to change them.
_: {
  flake.modules.nixos.service-endpoints =
    { lib, ... }:
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
                  description = "URL local consumers use to reach the ${name} service.";
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
    };
}
