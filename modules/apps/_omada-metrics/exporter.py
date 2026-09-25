import json
import os
import re
import ssl
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request

BASE = os.environ["OMADA_URL"].rstrip("/")
OUT = os.environ["TEXTFILE_OUT"]
CLIENT_ID_FILE = os.environ["CLIENT_ID_FILE"]
CLIENT_SECRET_FILE = os.environ["CLIENT_SECRET_FILE"]

# Generous: the controller is a JVM that can be busy applying a
# config push, and the timer interval is 2 minutes.
TIMEOUT = 15

# The controller generates its own cert on first boot and it is
# never valid for 127.0.0.1. Caddy skips verification on the
# same hop for the same reason.
CTX = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

# Every list endpoint requires page/pageSize as *mandatory*
# query params — omitting them is a bare Tomcat 400, not a
# JSON error. Sized well past this network; `totalRows` in the
# response is checked against what came back so a fleet that
# outgrows one page is visible rather than silently truncated.
PAGE_SIZE = 1000

# DeviceInfo.status, quoted from /v3/api-docs:
#   0: Disconnected; 1: Connected; 2: Pending;
#   3: Heartbeat Missed; 4: Isolated
# Only 1 is healthy, so `up` is `status == 1` and every other
# value — including ones a later controller may add — reads as
# down. The raw value is published alongside so an alert can be
# triaged without guessing which non-1 state it landed in.
STATUS_CONNECTED = 1

rows = {}
# One series per sub-request, so a partial failure is visible.
# Without this the exporter's worst failure is silent: revoked
# Open API credentials, a role change, or an endpoint renamed by
# a controller bump would all still rewrite the .prom on time —
# so OmadaMetricsStale stays quiet — while every device series
# simply vanishes. Verified by running this exporter against the
# live controller with a bogus client: controller_up stays 1,
# every device series disappears, and scrape_error{token} is the
# only thing that says so.
#
# Deliberately scoped to the *authenticated* path. A controller
# that is not answering /api/info at all publishes
# omada_controller_up 0 and no error series, because that case is
# already carried by SystemdUnitFailed on podman-omada.service
# and by GatusEndpointDown on the same port; folding it in here
# would put a third alert on one cause without adding a fact.
errors = {}


def emit(metric, mtype, help_text, label_str, value):
    rows.setdefault(metric, (mtype, help_text, []))[2].append((label_str, value))


def labels(**kwargs):
    def esc(v):
        return str(v).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")

    if not kwargs:
        return ""
    body = ",".join('%s="%s"' % (k, esc(v)) for k, v in sorted(kwargs.items()))
    return "{" + body + "}"


def read_secret(path):
    with open(path) as fh:
        return fh.read().strip()


def http(url, method="GET", token=None, body=None):
    data = None
    req_headers = {}
    if body is not None:
        data = json.dumps(body).encode()
        req_headers["Content-Type"] = "application/json"
    if token:
        # Omada's own scheme, not RFC 6750 Bearer.
        req_headers["Authorization"] = "AccessToken=%s" % token
    req = urllib.request.Request(url, data=data, headers=req_headers, method=method)
    with urllib.request.urlopen(req, timeout=TIMEOUT, context=CTX) as resp:
        return json.loads(resp.read().decode())


def api(endpoint, path, token, params=None):
    """GET an /openapi path, unwrap the errorCode envelope.

    Returns the `result` object, or None having recorded the
    failure against `endpoint`. Every caller must tolerate None.
    """
    url = BASE + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    try:
        payload = http(url, token=token)
    except Exception as exc:
        sys.stderr.write("%s: %s\n" % (endpoint, exc))
        errors[endpoint] = 1
        return None
    if payload.get("errorCode") != 0:
        sys.stderr.write(
            "%s: errorCode %s: %s\n" % (endpoint, payload.get("errorCode"), payload.get("msg"))
        )
        errors[endpoint] = 1
        return None
    errors.setdefault(endpoint, 0)
    return payload.get("result")


def paged(endpoint, path, token):
    """Collect every row of a paged list endpoint."""
    out = []
    page = 1
    while True:
        result = api(endpoint, path, token, {"page": page, "pageSize": PAGE_SIZE})
        if result is None:
            return out
        batch = result.get("data") or []
        out.extend(batch)
        total = result.get("totalRows")
        if not batch or total is None or len(out) >= total:
            return out
        page += 1


# Two shapes seen from the controller: "3h 28m 15s" from the
# device list (verified live), and "0 days 21:12:18" from the
# switch-detail endpoint. The day-crossing form of the first is
# unobserved, so both are tried and an unparseable string simply
# publishes no uptime series rather than a wrong number.
CLOCK_RE = re.compile(r"^(?:(\d+)\s*days?\s+)?(\d+):(\d+):(\d+)$")
TOKEN_RE = re.compile(r"(\d+)\s*(days?|[dhms])")
TOKEN_SECONDS = {"d": 86400, "day": 86400, "days": 86400, "h": 3600, "m": 60, "s": 1}


def parse_uptime(text):
    if not text:
        return None
    text = text.strip()
    clock = CLOCK_RE.match(text)
    if clock:
        days, hours, minutes, seconds = clock.groups()
        return (
            int(days or 0) * 86400 + int(hours) * 3600 + int(minutes) * 60 + int(seconds)
        )
    matches = TOKEN_RE.findall(text)
    if not matches:
        return None
    return sum(int(n) * TOKEN_SECONDS[unit] for n, unit in matches)


# ---- controller identity, no credentials needed -------------
# /api/info answers unauthenticated. It is also where omadacId
# comes from: the controller generates it at first run and a
# rebuilt controller gets a new one, so discovering it per run
# is what keeps this module from carrying a per-host constant
# that would silently go stale.
try:
    info = http(BASE + "/api/info")["result"]
    controller_up = 1
except Exception as exc:
    sys.stderr.write("/api/info failed: %s\n" % exc)
    info = {}
    controller_up = 0

emit(
    "omada_controller_up",
    "gauge",
    "Whether the Omada controller answered its unauthenticated /api/info endpoint.",
    labels(),
    controller_up,
)

omadac_id = info.get("omadacId")
if controller_up:
    emit(
        "omada_controller_info",
        "gauge",
        "Omada controller build, as a label set. Always 1.",
        labels(version=info.get("controllerVer", ""), omadac_id=omadac_id or ""),
        1,
    )


def scrape():
    if not omadac_id:
        return

    try:
        token_payload = http(
            BASE + "/openapi/authorize/token?grant_type=client_credentials",
            method="POST",
            body={
                "omadacId": omadac_id,
                "client_id": read_secret(CLIENT_ID_FILE),
                "client_secret": read_secret(CLIENT_SECRET_FILE),
            },
        )
    except Exception as exc:
        sys.stderr.write("token request failed: %s\n" % exc)
        errors["token"] = 1
        return
    if token_payload.get("errorCode") != 0:
        # -44106 is a revoked or rotated client; the message is
        # the only thing that distinguishes it from a role change.
        sys.stderr.write(
            "token: errorCode %s: %s\n"
            % (token_payload.get("errorCode"), token_payload.get("msg"))
        )
        errors["token"] = 1
        return
    errors["token"] = 0
    token = (token_payload.get("result") or {}).get("accessToken")

    root = "/openapi/v1/%s" % urllib.parse.quote(omadac_id, safe="")
    for site in paged("sites", root + "/sites", token):
        scrape_site(token, root, site)


def scrape_site(token, root, site):
    site_id = site.get("siteId")
    site_name = site.get("name") or site_id
    if not site_id:
        return
    site_root = "%s/sites/%s" % (root, urllib.parse.quote(site_id, safe=""))

    clients = paged("clients", site_root + "/clients", token)
    # connectDevType is ap / switch / gateway, with the MAC in
    # the matching field; counted per uplink device so the
    # per-device series works for APs and gateways too, not just
    # the switches this site happens to hold today.
    per_device_clients = {}
    for client in clients:
        uplink = client.get("switchMac") or client.get("apMac") or client.get("gatewayMac")
        if uplink:
            per_device_clients[uplink] = per_device_clients.get(uplink, 0) + 1

    counts = api("client-num", site_root + "/dashboard/current-client-num", token) or {}
    for kind, key in (("wired", "wiredClient"), ("wireless", "wirelessClient")):
        if key in counts:
            emit(
                "omada_site_client_count",
                "gauge",
                "Clients currently connected to this site, by connection kind.",
                labels(site=site_name, kind=kind),
                counts[key],
            )

    # totalPowerUsed / totalPower are per *device*, keyed by mac,
    # so this is folded into the device loop below rather than
    # published on its own.
    poe = api("poe-usage", site_root + "/dashboard/poe-usage", token) or []
    poe_by_mac = {row.get("mac"): row for row in poe if row.get("mac")}

    for device in paged("devices", site_root + "/devices", token):
        mac = device.get("mac")
        if not mac:
            continue
        common = dict(
            mac=mac,
            name=device.get("name") or mac,
            model=device.get("model") or "",
            site=site_name,
        )

        status = device.get("status")
        emit(
            "omada_device_up",
            "gauge",
            "Whether the controller reports this adopted device as Connected (status 1). Any other status, including Pending / Heartbeat Missed / Isolated, is 0.",
            labels(**common),
            int(status == STATUS_CONNECTED),
        )
        if status is not None:
            emit(
                "omada_device_status",
                "gauge",
                "Raw controller status enum: 0 Disconnected, 1 Connected, 2 Pending, 3 Heartbeat Missed, 4 Isolated.",
                labels(**common),
                status,
            )
        if device.get("detailStatus") is not None:
            emit(
                "omada_device_detail_status",
                "gauge",
                "Raw controller detailStatus enum, which splits each status into its cause (14 Connected, 12 Upgrading, 13 Rebooting, 24 Adopt Failed, 30 Heartbeat Missed, ...). See DeviceInfo.detailStatus in the controller's /v3/api-docs.",
                labels(**common),
                device["detailStatus"],
            )

        for field, metric, help_text in (
            ("cpuUtil", "omada_device_cpu_percent", "Device CPU utilisation, percent."),
            ("memUtil", "omada_device_mem_percent", "Device memory utilisation, percent."),
        ):
            if device.get(field) is not None:
                emit(metric, "gauge", help_text, labels(**common), device[field])

        uptime = parse_uptime(device.get("uptime"))
        if uptime is not None:
            emit(
                "omada_device_uptime_seconds",
                "gauge",
                "Device uptime, parsed from the controller's human-readable uptime string.",
                labels(**common),
                uptime,
            )

        if device.get("lastSeen"):
            emit(
                "omada_device_last_seen_seconds",
                "gauge",
                "Unix time the controller last heard from this device.",
                labels(**common),
                device["lastSeen"] / 1000.0,
            )

        emit(
            "omada_device_client_count",
            "gauge",
            "Clients the controller attributes to this device as their uplink.",
            labels(**common),
            per_device_clients.get(mac, 0),
        )

        if mac in poe_by_mac:
            row = poe_by_mac[mac]
            for field, metric, help_text in (
                (
                    "totalPowerUsed",
                    "omada_device_poe_watts",
                    "PoE power this device is currently delivering, watts.",
                ),
                (
                    "totalPower",
                    "omada_device_poe_budget_watts",
                    "This device's total PoE power budget, watts.",
                ),
            ):
                if row.get(field) is not None:
                    emit(metric, "gauge", help_text, labels(**common), row[field])

        scrape_firmware(token, site_root, device, common)


def scrape_firmware(token, site_root, device, common):
    """Per-device firmware currency.

    `DeviceFirmwareInfo` is `{curFwVer, lastFwVer, fwReleaseLog}`
    (from /v3/api-docs). `lastFwVer` is present only when a newer
    build exists — verified live in the up-to-date direction on
    both switches, which return `curFwVer` alone. The
    upgrade-available direction is documented by the schema and
    matches the shape of the controller's own `modelfw` cache in
    mongo, where the record for the version a device is on
    carries `last_fw_ver` + `fw_url` exactly when an upgrade is
    pending; it could not be verified live because neither switch
    had one outstanding.
    """
    mac = device["mac"]
    fw = api(
        "latest-firmware-info",
        "%s/devices/%s/latest-firmware-info" % (site_root, urllib.parse.quote(mac, safe="")),
        token,
    )
    current = device.get("firmwareVersion") or ""
    latest = ""
    available = 0
    if fw is not None:
        current = fw.get("curFwVer") or current
        latest = fw.get("lastFwVer") or ""
        available = int(bool(latest) and latest != current)

    emit(
        "omada_device_firmware_info",
        "gauge",
        "Device firmware, as a label set. `latest_version` is empty when the controller knows of no newer build. Always 1.",
        labels(version=current, latest_version=latest, **common),
        1,
    )
    if fw is not None:
        emit(
            "omada_device_firmware_upgrade_available",
            "gauge",
            "Whether the controller knows of a newer firmware build for this device than the one it is running.",
            labels(**common),
            available,
        )


scrape()

for endpoint in sorted(errors):
    emit(
        "omada_scrape_error",
        "gauge",
        "Whether the last read of this Open API endpoint failed. Catches revoked credentials, role changes and endpoints renamed by a controller upgrade — none of which stop the .prom being rewritten, so they are invisible to OmadaMetricsStale.",
        labels(endpoint=endpoint),
        errors[endpoint],
    )

# Atomic write via tempfile + rename, so node_exporter never
# reads a half-written file.
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(OUT), prefix=".omada.prom.")
with os.fdopen(fd, "w") as fh:
    for metric in sorted(rows):
        mtype, help_text, samples = rows[metric]
        fh.write("# HELP %s %s\n" % (metric, help_text))
        fh.write("# TYPE %s %s\n" % (metric, mtype))
        for label_str, value in samples:
            fh.write("%s%s %s\n" % (metric, label_str, repr(float(value))))
os.chmod(tmp, 0o644)
os.rename(tmp, OUT)
