# SSH - Multi Context Aspect
# Consolidates NixOS + home-manager SSH configuration
_: {
  flake.modules.homeManager.ssh-homelan = _: {
    programs.ssh = {
      settings = {
        "behemoth" = {
          HostName = "192.168.10.1";
          User = "admin";
          Port = 2222;
        };
        "laconia" = {
          HostName = "laconia.ipreston.net";
          User = "ipreston";
          Port = 2222;
          RequestTTY = "yes";
          RemoteCommand = "TERM=xterm-256color bash -l";
          IgnoreUnknown = "WarnWeakCrypto";
          WarnWeakCrypto = "no-pq-kex";
        };
      };
    };
  };
}
