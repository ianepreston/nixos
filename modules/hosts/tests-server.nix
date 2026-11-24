# tests-server - sacrificial VM target for `task recovery:test:full`.
# Imports the same server + server-apps profiles as hpp-1 so the
# restore drill exercises the real shape of a server. Single-disk
# btrfs with impermanence (rolled back to @root-blank on every boot)
# is fine here: the VM is deleted on teardown anyway, the impermanence
# layer matters to make `preservation-server` (pulled in by server
# profile) actually do its bind-mount work — without an impermanent
# root the bind-mounts run but have nothing to roll back.
{
  inputs,
  hostSpecs,
  config,
  ...
}:
{
  # networking.hostName is single-sourced from hostSpec by mkNixosHost.
  flake.nixosConfigurations.tests-server = config.flake.lib.mkNixosHost {
    inherit inputs;
    hostSpec = hostSpecs.tests-server;
    extraModules = [
      ./_tests-server-hardware.nix
      inputs.disko.nixosModules.disko
      ./_vm-disks.nix
    ]
    ++ (with inputs.self.modules.nixos; [
      server
      server-apps
    ])
    ++ [
      {
        boot.loader = {
          systemd-boot.enable = true;
          efi.canTouchEfiVariables = true;
        };

        networking = {
          networkmanager.enable = true;
        };

        # NetworkManager keeps its DHCP leases and the secret_key behind
        # stable-privacy IPv6 addresses in /var/lib/NetworkManager, which is
        # not preserved; see myAppStateAudit in modules/system/app-state.nix.
        myAppStateAudit.exemptions.networkmanager = {
          unit = "NetworkManager.service";
          directories = [ "/var/lib/NetworkManager" ];
          disposition = "pending";
          reason = "Unreviewed since the #1024 StateDirectory audit found it; preserve it with `myAppState` or re-declare it `disposable` with the reason.";
        };

        # Off the tailnet: the drill VM has no reason to join, and
        # tailnet.yaml deliberately does not list it (#506).
        services.tailscale.enable = false;

        system.stateVersion = "25.11";
      }
    ];
  };
}
