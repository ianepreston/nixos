# NixOS configs

I have so much stuff to fill in here.

# NixOS install

```bash
sudo nixos-rebuild switch --flake .
```

# Getting home manager working

```bash
nix shell nixpkgs#home-manager -c home-manager -b bak switch --flake .#ipreston@wsl
```
