{ ... }:
{
  services.ssh-agent.enable = true;
  xdg.mimeApps = {
    enable = true;
  };
  # Nicely reload system units when changing configs
  systemd.user.startServices = "sd-switch";
}
