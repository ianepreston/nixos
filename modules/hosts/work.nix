# Work - Darwin work machine
{
  inputs,
  hostSpecs,
  ...
}:
let
  hostSpec = hostSpecs.work;
in
{
  flake.darwinConfigurations.work = inputs.nix-darwin.lib.darwinSystem {
    specialArgs = {
      inherit inputs;
      inherit (inputs.nixpkgs-darwin) lib;
      inherit hostSpec;
    };
    modules = [
      inputs.self.modules.darwin.base
      inputs.self.modules.darwin.desktop
      inputs.self.modules.darwin.homebrew
      inputs.self.modules.darwin.yubikey
      inputs.nix-secrets.darwinModules.work
      {
        system.primaryUser = hostSpec.username;

        # Corporate DNS can't see the homelab, but behemoth (pfSense)
        # answers LAN queries directly for the whole ipreston.net zone
        # (including the *.amos wildcard and DHCP-registered hosts). A scoped
        # resolver sends only that suffix there; everything else stays on the
        # corporate resolver.
        environment.etc."resolver/${inputs.nix-secrets.domain}".text = ''
          nameserver 192.168.10.1
        '';

        home-manager.sharedModules = [
          inputs.self.modules.homeManager.coding-sandbox
          inputs.self.modules.homeManager.hammerspoon
          inputs.self.modules.homeManager.ghostty
          inputs.nix-secrets.homeManagerModules.work
        ];

        nixpkgs.hostPlatform = "aarch64-darwin";
        nix.enable = false;

        system.stateVersion = 6;
      }
    ];
  };
}
