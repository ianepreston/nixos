# SNMP exporter — pull metrics from external network devices: the
# pfSense router and Synology NAS over SNMPv2c, and the Omada switches
# and APs over SNMPv3.
#
# Why v2c rather than v3: pfSense's built-in `bsnmpd` is v1/v2c only
# — v3 means installing net-snmp from the FreeBSD package manager and
# hand-editing /usr/local/etc/snmpd.conf over SSH, which doesn't
# survive a config restore cleanly. Synology would do v3 trivially
# but mixing v3 here / v2c there isn't worth it when pfSense is the
# weak link. Defense in depth: each device's SNMP listener is
# restricted (on the device) to hpp-1's IP only, and the community
# string lives in encrypted sops, not plaintext in this repo.
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
# version it offers, so the switches and APs need their own auth
# entries. Those land as a *second* --config.file rather than another
# substitution into upstream's snmp.yml: snmp_exporter accepts the
# flag repeatedly and merges the files, and an auths-only file is
# valid on its own (verified against 0.30.1 with --dry-run). Nothing
# to sed here anyway — these credentials are ours, not an upstream
# default.
#
# Two Omada auths, not one, because EAP770/EAP772 firmware does not
# implement AuthPriv. Saving an AuthPriv site config makes the
# controller warn and silently apply AuthNoPriv + MD5 to the APs
# alone. So the switches keep SHA + AES and the APs get a weaker
# entry with the same username and password (v3 derives the localized
# key from the protocol, so one password serves both). The APs are on
# TRUST and what travels in the clear is clientCount / sysName /
# uptime; the shared password is not exposed by it. Re-test the APs
# against `omada_v3` after any AP firmware bump and delete
# `omada_v3_ap` when it answers.
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
      # All three secrets come from the shared file: both servers run
      # the observability stack and both poll the same devices.
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
                # Switches (192.168.15.x) — full AuthPriv.
                omada_v3:
                  version: 3
                  username: ${omadaSnmpUser}
                  security_level: authPriv
                  auth_protocol: SHA
                  password: ${config.sops.placeholder."snmp/v3_auth_password"}
                  priv_protocol: AES
                  priv_password: ${config.sops.placeholder."snmp/v3_priv_password"}
                # APs — firmware-forced AuthNoPriv + MD5, same credentials.
                omada_v3_ap:
                  version: 3
                  username: ${omadaSnmpUser}
                  security_level: authNoPriv
                  auth_protocol: MD5
                  password: ${config.sops.placeholder."snmp/v3_auth_password"}
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
