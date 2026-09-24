# SNMP exporter — pull metrics from external network devices: the
# pfSense router and Synology NAS over SNMPv2c, and the Omada switches
# and APs over SNMPv3.
#
# Why v2c rather than v3: pfSense's built-in `bsnmpd` is v1/v2c only
# — v3 means installing net-snmp from the FreeBSD package manager and
# hand-editing /usr/local/etc/snmpd.conf over SSH, which doesn't
# survive a config restore cleanly. Synology would do v3 trivially
# but mixing v3 here / v2c there isn't worth it when pfSense is the
# weak link. Defense in depth is the community string and the v3
# credentials living in encrypted sops rather than plaintext in this
# repo. There is no device-side source-IP restriction: this comment
# claimed until #728 that each listener was restricted to hpp-1's IP,
# and it never was — amos1 scraped every one of these devices for the
# whole of VictoriaMetrics' retained history. Only amos1 scrapes them
# now, but that is scrape-job gating in
# modules/system/victoriametrics.nix, not an ACL on the device.
#
# Shipped snmp.yml: prometheus-snmp-exporter ships a `snmp.yml` with
# generated modules for synology, if_mib, system, ip_mib, ucd_*, and
# a long list of vendor profiles — but no pfsense profile. pfSense
# bsnmpd exposes standard mibII (system, IF-MIB, IP-MIB) and not the
# UCD-SNMP load/memory tree, so for pfSense we use `if_mib` + `system`
# only. Synology gets the dedicated `synology` module plus `if_mib`
# + `system` + UCD load/memory.
#
# Threading the community in: snmp_exporter's --config.expand-
# environment-variables flag only substitutes envvars in auth
# `username` / `password` / `priv_password` (see config/config.go in
# the upstream src) — it does NOT touch `community`. So envFile is
# a dead-end for v2c. Instead we read the upstream snmp.yml at
# evaluation time, replace `community: public` with a sops placeholder
# token, and let sops-nix render the full file to /run/secrets-
# rendered/snmp.yml at activation. The rendered file is owned by
# snmp-exporter and never lands in the Nix store with the secret in
# it. enableConfigCheck is disabled because the configurationPath is
# now a runtime path, not a store path.
#
# Omada gear is SNMPv3, not v2c. The controller pushes one
# site-wide SNMP config to every device it manages and v3 is the only
# version it offers, so the Omada credentials land as a *second*
# --config.file rather than another substitution into upstream's
# snmp.yml: snmp_exporter accepts the flag repeatedly and merges the
# files, and an auths-only file is valid on its own (verified against
# 0.30.1 with --dry-run). Keeping them out of upstream's snmp.yml also
# leaves them readable YAML rather than a replaceStrings target.
# Nothing to sed here anyway — these credentials are ours, not an
# upstream default.
#
# One Omada auth covers both switches and APs. There were two until
# 2026-09-21: EAP770/EAP772 firmware 1.3.x did not implement AuthPriv,
# so saving an AuthPriv site config made the controller warn and
# silently apply AuthNoPriv + MD5 to the APs alone, and they needed
# their own weaker `omada_v3_ap` entry. Firmware 1.4.3 Build 20260818
# implements it: the APs began honouring the site's real
# authPriv/SHA/AES setting and rejected the weaker requests outright
# (`incoming packet is not authentic`), which broke the AP job until
# it was pointed at `omada_v3` (#686). A firmware rollback would be a
# deliberate act, and the deleted entry is recoverable from history.
#
# Listener is loopback-only; VictoriaMetrics scrapes locally via the
# multi-target relabel pattern in modules/system/victoriametrics.nix.
_: {
  flake.modules.nixos.snmp-exporter =
    {
      config,
      inputs,
      pkgs,
      ...
    }:
    let
      sopsFolder = "${inputs.nix-secrets}/sops";
      upstreamSnmpYml = builtins.readFile "${pkgs.prometheus-snmp-exporter.src}/snmp.yml";
      communityPlaceholder = config.sops.placeholder."snmp/community";
      # Must match Settings -> Site -> SNMP in the Omada controller.
      omadaSnmpUser = "omada_ro";
      # Both shipped auths (public_v1 and public_v2) have
      # `community: public`. Replacing them both is fine; we use
      # auth=public_v2 in the scrape jobs and the unused v1 entry
      # just inherits the same secret.
      renderedSnmpYml =
        builtins.replaceStrings [ "community: public\n" ] [ "community: ${communityPlaceholder}\n" ]
          upstreamSnmpYml;
    in
    {
      # All three secrets come from the shared file: the exporter runs
      # on both servers even though only amos1 carries the scrape jobs
      # (#728). Keeping it enabled on hpp-1 costs nothing while idle
      # and keeps the dev host usable for ad-hoc walks — it is the
      # diagnosis path #629, #686 and #693 were worked from.
      sops = {
        secrets = {
          "snmp/community".sopsFile = "${sopsFolder}/server-shared.yaml";
          "snmp/v3_auth_password".sopsFile = "${sopsFolder}/server-shared.yaml";
          "snmp/v3_priv_password".sopsFile = "${sopsFolder}/server-shared.yaml";
        };

        templates = {
          "snmp.yml" = {
            content = renderedSnmpYml;
            owner = "snmp-exporter";
            group = "snmp-exporter";
            restartUnits = [ "prometheus-snmp-exporter.service" ];
          };

          "snmp-omada.yml" = {
            content = ''
              auths:
                # Switches (192.168.15.x) and APs — full AuthPriv, the
                # site-wide setting. The controller's Privacy Mode must
                # be AES to match: a DES/AES mismatch is silently
                # dropped by the switch and reads as a plain request
                # timeout (#629).
                omada_v3:
                  version: 3
                  username: ${omadaSnmpUser}
                  security_level: authPriv
                  auth_protocol: SHA
                  password: ${config.sops.placeholder."snmp/v3_auth_password"}
                  priv_protocol: AES
                  priv_password: ${config.sops.placeholder."snmp/v3_priv_password"}
            '';
            owner = "snmp-exporter";
            group = "snmp-exporter";
            restartUnits = [ "prometheus-snmp-exporter.service" ];
          };
        };
      };

      # The prometheus exporters module defaults to DynamicUser=true,
      # which means systemd seeds `snmp-exporter` only when the
      # service runs. sops-install-secrets runs earlier in activation
      # and fails on `chown snmp-exporter:` when that user hasn't
      # materialized yet. Declaring it statically here makes the
      # user resolvable before the service starts, and systemd
      # adopts it as the dynamic identity.
      users.users.snmp-exporter = {
        isSystemUser = true;
        group = "snmp-exporter";
      };
      users.groups.snmp-exporter = { };

      services.prometheus.exporters.snmp = {
        enable = true;
        listenAddress = "127.0.0.1";
        configurationPath = config.sops.templates."snmp.yml".path;
        # configurationPath is a runtime path under /run; the build-
        # time dry-run check needs a store path.
        enableConfigCheck = false;
        # The module renders its own --config.file first; this one is
        # appended after it and merged in. Split out rather than
        # folded into the rendered snmp.yml above so the Omada
        # credentials stay readable as YAML instead of a
        # replaceStrings target.
        extraFlags = [
          "--config.file=${config.sops.templates."snmp-omada.yml".path}"
        ];
      };
    };
}
