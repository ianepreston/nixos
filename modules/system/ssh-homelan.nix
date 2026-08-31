# SSH - Multi Context Aspect
# Consolidates NixOS + home-manager SSH configuration
_: {
  flake.modules.homeManager.ssh-homelan = _: {
    programs.ssh = {
      settings = {
        "switch" = {
          # ProCurve at OpenSSH 3.7.1p2 predates connection multiplexing
          # and serves one session per connection, so opt it out of the
          # fleet-wide ControlMaster set in ssh.nix. Named blocks are
          # emitted before `Host *`, so this wins.
          ControlMaster = "no";
          HostName = "192.168.10.2";
          User = "admin";
          KexAlgorithms = "+diffie-hellman-group1-sha1,diffie-hellman-group-exchange-sha1";
          PubkeyAcceptedKeyTypes = "+ssh-rsa";
          HostKeyAlgorithms = "+ssh-rsa";
          Ciphers = "+3des-cbc";
        };
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
