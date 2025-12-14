{ pkgs, ... }:
{
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
    };
  };
}
