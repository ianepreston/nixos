# Core functionality for every nixos host
{ config, lib, customLib, ... }:
{
  # Database for aiding terminal-based programs
  environment.enableAllTerminfo = true;
  # Enable firmware with a license allowing redistribution
  hardware.enableRedistributableFirmware = true;

  # This should be handled by config.security.pam.sshAgentAuth.enable
  security.sudo.extraConfig = ''
    Defaults lecture = never # rollback results in sudo lectures after each reboot, it's somewhat useless anyway
    Defaults pwfeedback # password input feedback - makes typed password visible as asterisks
    Defaults timestamp_timeout=120 # only ask for password every 2h
    # Keep SSH_AUTH_SOCK so that pam_ssh_agent_auth.so can do its magic.
    Defaults env_keep+=SSH_AUTH_SOCK
  '';

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;
  #
  # ========== Nix Helper ==========
  #
  # Provide better build output and will also handle garbage collection in place of standard nix gc (garbage collection)
  # Add this back in once you have hostSpec sorted out
  # programs.nh = {
  #   enable = true;
  #   clean.enable = true;
  #   clean.extraArgs = "--keep-since 20d --keep 20";
  #   flake = "/home/user/${config.hostSpec.home}/nixos";
  # };
  #
  #
  # ========== Localization ==========
  #
  i18n.defaultLocale = lib.mkDefault "en_CA.UTF-8";
  time.timeZone = lib.mkDefault "America/Edmonton";
  imports = lib.flatten [
    (map customLib.relativeToRoot [
    "hosts/common/core/ssh.nix"
    "hosts/common/core/sops.nix"
    ])
]; 
  #
  # ========== Nix Nix Nix ==========
  #
  nix = {
    # Map all inputs to the registry, but explicitly override 'nixpkgs' based on the OS
    # lib.mkForce ensures that built-in OS defaults don't conflict with our custom routing.
    registry = (lib.mapAttrs (_: value: { flake = value; }) inputs) // {
      nixpkgs.flake = lib.mkForce (if hostSpec.isDarwin then inputs.nixpkgs-darwin else inputs.nixpkgs);
    };

    # This will add your inputs to the system's legacy channels
    nixPath = lib.mapAttrsToList (key: value: "${key}=${value.to.path}") config.nix.registry;
    optimise.automatic = true;

    settings = {
      # See https://jackson.dev/post/nix-reasonable-defaults/
      connect-timeout = 5;
      log-lines = 25;
      min-free = 128000000; # 128MB
      max-free = 1000000000; # 1GB

      trusted-users = [ "@wheel" ];
      warn-dirty = false;

      allow-import-from-derivation = true;

      experimental-features = [
        "nix-command"
        "flakes"
      ];
    };
  };
}
