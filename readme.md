# NixOS configs

I have so much stuff to fill in here.

# Setting up WiFi from the minimal installer

Thanks [Arch wiki](https://wiki.archlinux.org/title/Wpa_supplicant), I still love you even if I'm running nix now.

```bash
# Start wpa_supplicant
sudo systemctl start wpa_supplicant
wpa_cli
add_network
set_network 0 ssid "MYSSID"
set_network 0 psk "passphrase"
enable_network 0
# Don't run save config like in the Arch wiki since this is nix, it will still work for this session
quit
```
