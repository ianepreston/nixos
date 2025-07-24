# Generated via dconf2nix: https://github.com/gvolpe/dconf2nix
{lib, ...}:
with lib.hm.gvariant; {
  dconf.settings = {
    "org/gnome/mutter/keybindings" = {
      toggle-tiled-left = ["<Super>Left"];
      toggle-tiled-right = ["<Super>Right"];
    };

    "org/gnome/settings-daemon/plugins/media-keys" = {
      custom-keybindings = ["/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0/"];
      home = ["<Super>e"];
      www = ["<Super>f"];
    };

    "org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom0" = {
      binding = "<Super>t";
      command = "kgx";
      name = "Launch Terminal";
    };

    "org/gnome/shell/extensions/paperwm" = {
      restore-keybinds = ''
        {"toggle-tiled-left":{"bind":"[\\"<Super>Left\\"]","schema_id":"org.gnome.mutter.keybindings"},"toggle-tiled-right":{"bind":"[\\"<Super>Right\\"]","schema_id":"org.gnome.mutter.keybindings"}}
      '';
    };

    "org/gnome/shell/keybindings" = {
      show-screenshot-ui = ["<Shift><Super>s"];
    };
  };
}
