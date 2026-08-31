# Security alert rules — the log-derived half.
#
# Closes the gap found by the 2026-08-26 monitoring review: of the 34
# alert rules on these hosts, none were security rules. The checklist
# in "Homelab Audit Scope, Threat Model and Checklist" §5 asks for
# repeated auth failures, config-change events, and new-device
# detection; this module covers the first two.
#
# Why a *second* vmalert instance. vmalert takes exactly one
# `-datasource.url`, and these rules query VictoriaLogs, not
# VictoriaMetrics. VictoriaLogs speaks a Prometheus-shaped query API
# only at `/select/logsql/stats_query`, which vmalert reaches by
# marking a group `type: vlogs` — but the datasource URL is a
# process-wide flag, so a vlogs group cannot live alongside the
# PromQL groups in victoriametrics.nix. Hence `vmalert-logs.service`
# next to `vmalert-main.service`, same notifier, same alertmanager,
# same Discord receiver, same Watchdog guarantee.
#
# Where the rest of the security rules live: `CertificateExpiringSoon`
# is a metrics rule (it reads gatus's `gatus_results_certificate_
# expiration_seconds`) so it sits in the `security` rule group in
# ./victoriametrics.nix. This file is the log-derived half only.
#
# vlogs group semantics, which drive how these rules are written:
#   * vmalert prepends `_time:<group interval>` to every expression,
#     so the group's `interval` IS the detection window. Don't put a
#     `_time` filter in the expression — that disables backfilling and
#     desynchronises the window from the evaluation cadence.
#   * The expression must end in a `stats` pipe; the resulting rows
#     become alert series, the `stats by (...)` fields become labels,
#     and the stats value becomes `$value`.
#   * A row existing is what fires the alert, so `| filter <n>:>K`
#     is the threshold. Rules with no `filter` fire on any occurrence,
#     which is the right default for events that should never happen.
#   * No `for:` on any of these. The window already does the
#     aggregating; a `for:` would additionally require the same
#     condition across two consecutive windows and just add latency.
#
# The UI is loopback-only and deliberately not registered in
# `myAuthentik.forwardAuthApps` (unlike vmalert-main). A second rules
# UI is worth little over `curl 127.0.0.1:8882/api/v1/rules` through
# an SSH forward, and this is the module where extra reachable
# surface is the thing being argued against. Flip it to a forward-auth
# app if the rule state ever needs to be checked from a phone.
_: {
  flake.modules.nixos.security-alerts =
    _:
    let
      # 8880 is vmalert's default (taken by the UniFi controller),
      # 8881 is vmalert-main; this is the next one along.
      vmalertLogsPort = 8882;
      victorialogsPort = 9428;
      victoriametricsPort = 8428;
      alertmanagerPort = 9093;

      # pfSense's syslog `hostname`, normalised into `host` by the
      # pfsense_enrich transform in ./vector.nix. Hardcoded rather
      # than derived from hostSpec: there is exactly one router, it
      # is the same one for every host in this flake, and the
      # firewall rule in vector.nix already hardcodes its address.
      routerHost = "behemoth.ipreston.net";

      # Authentik writes structured JSON to stdout, which journald
      # (and therefore VictoriaLogs) stores as an opaque `_msg`
      # string — the fields are not indexed. `unpack_json fields
      # (...)` parses just the two keys these rules need, at query
      # time, over the handful of lines the preceding word filters
      # already selected. Parsing at ingest in vector.nix was the
      # alternative; it was not worth widening every authentik log
      # line's column set to serve two alert rules.
      #
      # Two distinct failures reach this filter, confirmed by
      # driving both against a live authentik:
      #   unknown username  -> {"event": "invalid_login",
      #                         "action": "invalid_identifier"}
      #   wrong password    -> {"event": "Created Event",
      #                         "action": "login_failed"}
      # The leading word filters are pure selectivity — `action`
      # is what actually decides.
      authentikLoginFailures = ''
        unit:="authentik.service" ("login_failed" or "invalid_login")
          | unpack_json fields (action, client_ip)
          | filter action:in("login_failed", "invalid_identifier")'';
    in
    {
      services.vmalert.instances.logs = {
        enable = true;
        settings = {
          # VictoriaLogs, not VictoriaMetrics — see the header.
          "datasource.url" = "http://127.0.0.1:${toString victorialogsPort}";
          "notifier.url" = [ "http://127.0.0.1:${toString alertmanagerPort}" ];
          "httpListenAddr" = "127.0.0.1:${toString vmalertLogsPort}";
          # Every group here sets its own `interval`; this only
          # covers a group that forgets to.
          "evaluationInterval" = "5m";
          # Alert state goes to VictoriaMetrics even though the
          # queries don't come from it — same rationale as
          # vmalert-main: remoteWrite emits the ALERTS /
          # ALERTS_FOR_STATE series so there is a record of what
          # fired after it resolves, and remoteRead restores
          # pending state so a restart doesn't reset the windows.
          "remoteWrite.url" = "http://127.0.0.1:${toString victoriametricsPort}";
          "remoteRead.url" = "http://127.0.0.1:${toString victoriametricsPort}";
        };

        rules.groups = [
          {
            name = "security-auth";
            type = "vlogs";
            # 5m detection window. Short enough that a brute-force
            # run is caught while it is still running, long enough
            # that the per-IP threshold below is well clear of a
            # human retrying a password.
            interval = "5m";
            rules = [
              {
                # Authentik is the front door for ~30 services and
                # is single-factor for every user until MFA lands,
                # so this is the highest-value rule in the file.
                #
                # >10 in 5m per source: a person mistyping a
                # password gives up well before ten attempts, and
                # the observed baseline over 30d is zero. Tighten
                # once MFA is enforced and this stops carrying the
                # brute-force load on its own.
                alert = "AuthentikRepeatedLoginFailures";
                expr = ''
                  ${authentikLoginFailures}
                    | stats by (client_ip) count() as failures
                    | filter failures:>10
                '';
                labels.severity = "warning";
                annotations = {
                  summary = "{{ $value }} failed authentik logins from {{ $labels.client_ip }}";
                  description = "authentik rejected {{ $value }} login attempts from {{ $labels.client_ip }} in 5 minutes (unknown username or wrong password). Every user is still single-factor, so treat a sustained run as a credential-stuffing attempt: check Events → Logins in the authentik UI for which accounts were targeted.";
                };
              }
              {
                # The per-source rule above cannot see a
                # credential-stuffing run that spreads a few
                # attempts across many addresses — each source
                # stays under the threshold. Counting *distinct*
                # sources instead of attempts is the signal that
                # is specific to that shape, so the two rules
                # don't double-fire on the same event.
                #
                # >5 sources in 5m: normal operation produces
                # failures from at most one or two addresses (a
                # person, on one or two devices).
                alert = "AuthentikDistributedLoginFailures";
                expr = ''
                  ${authentikLoginFailures}
                    | stats count_uniq(client_ip) as sources
                    | filter sources:>5
                '';
                labels.severity = "critical";
                annotations = {
                  summary = "Failed authentik logins from {{ $value }} distinct sources";
                  description = "authentik rejected logins from {{ $value }} distinct client IPs in 5 minutes. Spread across sources rather than concentrated, which is the shape of credential stuffing rather than one wrong password. Check Events → Logins in the authentik UI.";
                };
              }
              {
                # Shell-level auth failure on the servers
                # themselves. Both halves of this are events that
                # should never happen here, so there is no
                # threshold — one occurrence fires:
                #   * SSH is keys-only
                #     (`PasswordAuthentication = false` in
                #     ./ssh.nix), so a password failure means the
                #     setting moved.
                #   * wheel is NOPASSWD
                #     (`security.sudo.wheelNeedsPassword = false`
                #     in ../profiles/base.nix), so a sudo PAM
                #     failure or a `NOT in sudoers` denial means
                #     something outside wheel reached for root.
                # The observed 30d baseline across both servers is
                # zero, which is what makes a zero threshold
                # affordable.
                alert = "HostAuthenticationFailure";
                expr = ''
                  SYSLOG_IDENTIFIER:in("sudo", "su", "login", "sshd", "sshd-session")
                    ("authentication failure" or "NOT in sudoers"
                     or "Failed password" or "Invalid user")
                    | stats by (host, SYSLOG_IDENTIFIER) count() as failures
                '';
                labels.severity = "warning";
                annotations = {
                  summary = "{{ $value }} {{ $labels.SYSLOG_IDENTIFIER }} auth failure(s) on {{ $labels.host }}";
                  description = "{{ $labels.host }} logged {{ $value }} authentication failure(s) from {{ $labels.SYSLOG_IDENTIFIER }} in 5 minutes. SSH is keys-only and wheel is NOPASSWD on these hosts, so neither should occur in normal operation. Run: journalctl -t {{ $labels.SYSLOG_IDENTIFIER }} --since -15m";
                };
              }
              {
                # The router's own web front door. Its log line is
                #   webConfigurator authentication error for user
                #   'ian' from: 192.168.10.35
                # so user and source come straight out of the
                # message. >2 in 5m rather than >0: unlike the
                # server rules above, this login is password-based
                # and a mistyped password is expected.
                alert = "PfsenseWebConfigLoginFailures";
                expr = ''
                  host:="${routerHost}" "webConfigurator authentication error"
                    | extract "for user '<pf_user>' from: <pf_client_ip>"
                    | stats by (pf_user, pf_client_ip) count() as failures
                    | filter failures:>2
                '';
                labels.severity = "warning";
                annotations = {
                  summary = "{{ $value }} pfSense webConfigurator login failures for {{ $labels.pf_user }}";
                  description = "The pfSense web UI rejected {{ $value }} login attempts for user {{ $labels.pf_user }} from {{ $labels.pf_client_ip }} in 5 minutes. The router's rule base is the only thing scoping several trust boundaries, so an unexplained run here matters more than the count suggests.";
                };
              }
            ];
          }
          {
            name = "security-config";
            type = "vlogs";
            interval = "5m";
            rules = [
              {
                # pfSense has `logconfigchanges` enabled, so every
                # `write_config()` emits
                #   <page>: Configuration Change: <actor>: <what>
                # where actor is either `user@ip (Local Database)`
                # or `(system)` for package/service-driven writes.
                # Both halves come out of the message, so the
                # Discord notification names who changed what
                # rather than just that something changed.
                #
                # No threshold: the point of this rule is that a
                # silent change to the rule base is exactly the
                # thing the segmentation review said nothing would
                # catch. Measured volume over ~10 months of the
                # router's retained logs is 132 changes (~13/month),
                # so firing on every one is affordable. That
                # includes routine acme certificate stores; they
                # are left in rather than filtered, because an
                # allow-list of "boring" changes is the kind of
                # thing that silently grows to cover the
                # interesting ones.
                alert = "PfsenseConfigChange";
                expr = ''
                  host:="${routerHost}" "Configuration Change"
                    | extract "Configuration Change: <pf_actor>: <pf_change>"
                    | stats by (pf_actor, pf_change) count() as changes
                '';
                labels.severity = "warning";
                annotations = {
                  summary = "pfSense config changed by {{ $labels.pf_actor }}";
                  description = "{{ $labels.pf_actor }} changed the pfSense configuration: {{ $labels.pf_change }}. If that was not you, the config history at Diagnostics → Backup & Restore → Config History has the diff and can roll it back.";
                };
              }
            ];
          }
        ];
      };
    };
}
