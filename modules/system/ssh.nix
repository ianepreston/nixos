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

        knownHosts = {
          "github.com-ed25519" = {
            hostNames = [ "github.com" ];
            publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
          };
          "github.com-rsa" = {
            hostNames = [ "github.com" ];
            publicKey = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk=";
          };
          "github.com-ecdsa" = {
            hostNames = [ "github.com" ];
            publicKey = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=";
          };
        };
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
      settings = {
        "*" = {
          ForwardAgent = false;
          AddKeysToAgent = "no";
          Compression = false;
          # Non-zero is load-bearing for the `ControlPersist yes` below.
          # A master whose peer rebooted or dropped off the network leaves
          # a stale socket behind, and with no keepalive every subsequent
          # ssh to that host blocks on it indefinitely. At a 10m persist
          # the socket aged out on its own; with no bound it doesn't.
          ServerAliveInterval = 60;
          ServerAliveCountMax = 3;
          HashKnownHosts = false;
          UserKnownHostsFile = "~/.ssh/known_hosts";
          # Multiplex connections. Hardware-backed keys require a touch
          # per *signature* — the agent can't absorb that — so every
          # unmultiplexed connection costs another touch. The recipes in
          # taskfiles/{recovery,bootstrap}.yaml fire many discrete ssh
          # calls per run; one master collapses them into a single touch.
          # (`nixos-rebuild` already multiplexes internally over its own
          # ControlPath, so `task deploy:*` was never the worst offender.)
          #
          # ControlPath deliberately sits directly in ~/.ssh rather than
          # the ~/.ssh/sockets dir base.nix creates: penguin loads this
          # module as a standalone home-manager config with no NixOS
          # tmpfiles rule behind it, and a missing socket dir degrades to
          # an unmultiplexed connection with only a warning.
          ControlMaster = "auto";
          ControlPath = "~/.ssh/master-%r@%n:%p";
          # ControlPersist is `yes` — persist until `ssh -O exit` —
          # rather than a timeout: the goal is one PIN + touch per host
          # per session, and any finite window just re-bills the touch on
          # the far side of it.
          #
          # ssh-agent is not an alternative — it holds the sk credential
          # handle, but ssh-sk-helper is forked per *signature* and goes
          # back to the token every time, so `ssh-add -t` caches nothing
          # for a hardware key.
          #
          # This does trade away part of what the sk keys buy: an
          # attacker on this machine gets a free ride on masters that are
          # already open. They still can't open a session to a host that
          # has no live master without a touch.
          ControlPersist = "yes";
        };
      };
    };
  };
}
