# Recovering from a sops decryption failure

If `sops-install-secrets.service` fails on boot (most commonly: the host's age
key isn't present yet, the secret was re-encrypted against a different key, or a
YAML file is malformed), any service that reads the missing secret via a script
will hit a no-op guard or auth-fail. The current safety net for postgres roles
is the `unitConfig.ConditionPathExists` on `<app>-db-password.service` (see
`modules/system/postgresql.nix`): the unit refuses to run if the secret file is
missing, so it can't silently `ALTER USER … WITH PASSWORD ''` and lock the app
out of its DB.

To recover after the underlying sops issue is fixed:

```bash
# 1. Re-run decryption.
sudo systemctl start sops-install-secrets.service
# 2. Re-apply any role passwords that no-op'd while the secret was missing.
sudo systemctl start <app>-db-password.service
# 3. Restart the consumer service to pick up the (now correct) password.
sudo systemctl restart <app>.service   # or podman-<app>.service
```

`systemctl status sops-install-secrets` shows which secret failed;
`journalctl -u sops-install-secrets` has the underlying decryption error. The
`*-db-password` units are oneshots, so re-running them is always safe — they
just ALTER USER with whatever password is currently in the decrypted file.
