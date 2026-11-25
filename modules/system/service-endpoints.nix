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
      # Why a `containerUrl` is refused, or null. Whitespace and control
      # characters are refused outright because URL parsers strip them
      # (`local<TAB>host` reads as `localhost`), and userinfo because a
      # container URL must not embed credentials.
      containerUrlProblem =
        url:
        let
          m = builtins.match "[a-z][a-z0-9+.-]*://([^/?#]*).*" (lib.toLower url);
        in
        if builtins.match "[^[:space:][:cntrl:]]*" url == null then
          "contains whitespace or a control character"
        else if m != null && lib.hasInfix "@" (lib.head m) then
          "carries userinfo (`user@` before the host); a container URL must not embed credentials"
        else if !(reachableHost url) then
          "must be an absolute URL whose host a container can reach (normally host.containers.internal); a loopback or wildcard host names the container itself"
        else
          null;

      # Whether a `containerUrl` host can name something other than the
      # container itself. Only literal spellings are judged: loopback and
      # wildcard names and addresses in any form a resolver accepts (port
      # and a trailing dot removed; IPv6 expanded, including IPv4-mapped
      # and -compatible forms). Whether a host *name* resolves to the host
      # from the bridge is the producer's responsibility.
      reachableHost =
        url:
        let
          m = builtins.match "[a-z][a-z0-9+.-]*://([^/?#]*).*" (lib.toLower url);
          hostPort = lib.head m;
          v6 = builtins.match "\\[([0-9a-f:.]+)(%[^]]*)?](:[0-9]*)?" hostPort;
          # `%` would be percent-decoded into the name.
          named = builtins.match "([^]:[%]+)(:[0-9]*)?" hostPort;
        in
        if m == null then
          false
        else if v6 != null then
          reachableV6 (lib.head v6)
        else if named != null then
          reachableName (stripDots (lib.head named))
        else
          false;

      # Trailing dots name the same host.
      stripDots =
        name:
        let
          m = builtins.match "(.*[^.])[.]*" name;
        in
        if m == null then "" else lib.head m;

      # Canonical dotted-quad octets, or null.
      octets =
        s:
        let
          m = builtins.match "(0|[1-9][0-9]?[0-9]?)\\.(0|[1-9][0-9]?[0-9]?)\\.(0|[1-9][0-9]?[0-9]?)\\.(0|[1-9][0-9]?[0-9]?)" s;
          os = map lib.toInt m;
        in
        if m != null && lib.all (o: o <= 255) os then os else null;
      # 127/8 is loopback and 0/8 is "this host".
      reachableV4 =
        os:
        os != null
        && !(lib.elem (lib.head os) [
          0
          127
        ]);

      reachableName =
        name:
        let
          # A resolver also reads integer, octal and hex spellings of an
          # address, so a numeric-looking host must be a canonical
          # dotted quad.
          numeric = lib.all (l: builtins.match "[0-9]+|0x[0-9a-f]*" l != null) (lib.splitString "." name);
        in
        name != ""
        && name != "localhost"
        && !(lib.hasSuffix ".localhost" name)
        && (!numeric || reachableV4 (octets name));

      # `n` colon-separated 16-bit groups with any `::` expanded and leading
      # zeros dropped, or null.
      v6Groups =
        n: addr:
        let
          halves = lib.splitString "::" addr;
          split = h: if h == "" then [ ] else lib.splitString ":" h;
          left = split (lib.head halves);
          right = if lib.length halves == 2 then split (lib.elemAt halves 1) else [ ];
          fill = n - lib.length left - lib.length right;
          groups = if lib.length halves == 1 then left else left ++ lib.replicate fill "0" ++ right;
        in
        if
          lib.length halves <= 2
          && (lib.length halves == 1 || fill >= 1)
          && lib.length groups == n
          && lib.all (g: builtins.match "[0-9a-f][0-9a-f]?[0-9a-f]?[0-9a-f]?" g != null) groups
        then
          map (g: lib.head (builtins.match "0*([0-9a-f]+)" g)) groups
        else
          null;

      # `::`, `::1` and the IPv4-mapped (`::ffff:`) and -compatible (`::`)
      # forms of 0/8 and 127/8 all name the container itself.
      reachableV6 =
        addr:
        let
          tail = builtins.match "(.*):([0-9]+\\.[0-9.]*)" addr;
          prefix = v6Groups (if tail == null then 8 else 6) (
            if tail == null then
              addr
            else
              let
                p = lib.head tail;
              in
              # `::1.2.3.4` leaves an empty group before the address.
              if lib.hasSuffix ":" p then "${p}:" else p
          );
          v4 = if tail == null then null else octets (lib.elemAt tail 1);
          embedsV4 =
            prefix != null
            && lib.all (g: g == "0") (lib.take 5 prefix)
            && lib.elem (lib.elemAt prefix 5) [
              "0"
              "ffff"
            ];
          # The high group of an embedded address: 0/8 is below 0x100.
          high = lib.elemAt prefix 6;
          localHigh = lib.stringLength high <= 2 || (lib.stringLength high == 4 && lib.hasPrefix "7f" high);
        in
        prefix != null
        && (if tail != null then v4 != null && (!embedsV4 || reachableV4 v4) else !(embedsV4 && localHigh));
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
                    it. Never a loopback or wildcard address: an assertion
                    rejects every literal spelling of one, as well as
                    userinfo and any whitespace or control character. That a host name
                    resolves to this host from inside a container is the
                    producer's responsibility.
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
            problem = containerUrlProblem endpoint.containerUrl;
          in
          lib.optional (endpoint.containerUrl != null) {
            assertion = problem == null;
            message = "myServiceEndpoints.${name}.containerUrl: `${endpoint.containerUrl}` ${problem}.";
          }
        ) config.myServiceEndpoints
      );
    };
}
