# SSH - Multi Context Aspect
# Consolidates NixOS + home-manager SSH configuration
{ inputs, ... }:
{
  # NixOS-level SSH configuration
  flake.modules.nixos.ssh =
    { lib, pkgs, ... }:
    {
      services.openssh = {
        enable = true;
        settings.PasswordAuthentication = false;
      };

      programs.ssh = lib.optionalAttrs pkgs.stdenv.isLinux {
        startAgent = true;
        enableAskPassword = true;
        askPassword = pkgs.lib.mkForce "${pkgs.kdePackages.ksshaskpass.out}/bin/ksshaskpass";

        knownHostsFiles = [
          (pkgs.writeText "custom_known_hosts" ''
            github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
            github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=
            github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=
          '')
        ];
      };

      # Automatically include home-manager SSH config for all users
      home-manager.sharedModules = [
        inputs.self.modules.homeManager.ssh
      ];
    };

  # Home-manager-level SSH configuration
  flake.modules.homeManager.ssh = _: {
    programs.ssh = {
      enable = true;
      enableDefaultConfig = false;
      matchBlocks = {
        "*" = {
          forwardAgent = false;
          addKeysToAgent = "no";
          compression = false;
          serverAliveInterval = 0;
          serverAliveCountMax = 3;
          hashKnownHosts = false;
          userKnownHostsFile = "~/.ssh/known_hosts";
          controlMaster = "no";
          controlPath = "~/.ssh/master-%r@%n:%p";
          controlPersist = "no";
        };
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
