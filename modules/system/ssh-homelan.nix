# SSH - Multi Context Aspect
# Consolidates NixOS + home-manager SSH configuration
_: {
  flake.modules.homeManager.ssh-homelan = _: {
    programs.ssh = {
      matchBlocks = {
        "switch" = {
          hostname = "192.168.10.2";
          user = "admin";
          extraOptions = {
            "KexAlgorithms" = "+diffie-hellman-group1-sha1,diffie-hellman-group-exchange-sha1";
            "PubkeyAcceptedKeyTypes" = "+ssh-rsa";
            "HostKeyAlgorithms" = "+ssh-rsa";
            "Ciphers" = "+3des-cbc";
          };
        };
        "laconia" = {
          hostname = "laconia.ipreston.net";
          user = "ipreston";
          port = 2222;
          extraOptions = {
            "RequestTTY" = "yes";
            "RemoteCommand" = "TERM=xterm-256color bash -l";
            "IgnoreUnknown" = "WarnWeakCrypto";
            "WarnWeakCrypto" = "no-pq-kex";
          };
        };
      };
    };
  };
}
