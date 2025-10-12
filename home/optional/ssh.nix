{ pkgs, ... }:
{
  programs.ssh = {
    enable = true;
    extraConfig = ''
      Host switch
          HostName 192.168.10.2
          User admin
          KexAlgorithms +diffie-hellman-group1-sha1,diffie-hellman-group-exchange-sha1
          PubkeyAcceptedKeyTypes +ssh-rsa
          HostKeyAlgorithms +ssh-rsa
          Ciphers +3des-cbc
    '';

  };
}
