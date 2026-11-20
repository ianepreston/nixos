# For every nixosConfiguration that imports sops-nix: the nix-secrets sops
# files its NixOS and home-manager secrets read, by basename. Consumed by
# scripts/sops-recipient-matrix.py through `task secrets:matrix`.
configs:
let
  # Basenames only, so drop the store-path context attrNames rejects.
  files =
    secrets:
    map (s: builtins.unsafeDiscardStringContext (baseNameOf s.sopsFile)) (builtins.attrValues secrets);
  uniq =
    xs:
    builtins.attrNames (
      builtins.listToAttrs (
        map (name: {
          inherit name;
          value = null;
        }) xs
      )
    );
  consumed =
    c:
    uniq (
      files c.sops.secrets
      ++ builtins.concatMap (u: files (c.home-manager.users.${u}.sops.secrets or { })) (
        builtins.attrNames (c.home-manager.users or { })
      )
    );
  withSops = builtins.filter (n: configs.${n}.config ? sops) (builtins.attrNames configs);
in
builtins.listToAttrs (
  map (n: {
    name = n;
    value = consumed configs.${n}.config;
  }) withSops
)
