"""Post LubeLogger reminders that have become due to a Discord webhook.

LubeLogger's own webhook fires on record CRUD only, never when a
reminder crosses into an urgent tier, and its due-reminder delivery
is email. This fills that gap: once a day, read every vehicle's
reminders over the API, keep the Urgent / Very Urgent / Past Due
ones, and post the ones whose tier changed since the last run.

Dedupe is "post on tier change": the state file maps reminder id to
the tier last posted. A reminder that stays Past Due posts once; one
that escalates Urgent -> Very Urgent posts again. A reminder that
drops out of the urgent tiers (serviced, or its recurrence rolled
forward) is forgotten, so its next due cycle posts afresh.
"""

import base64
import json
import os
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

BASE = os.environ["LUBELOGGER_URL"].rstrip("/")
PUBLIC_URL = os.environ["LUBELOGGER_PUBLIC_URL"].rstrip("/")
STATE_FILE = Path(os.environ["STATE_FILE"])
CREDS = Path(os.environ["CREDENTIALS_DIRECTORY"])

TIMEOUT = 30

# The timer is Persistent, so after a reboot that missed 08:00 this
# runs while .NET is still starting; a restart of lubelogger.service
# near 08:00 (deploy, sops rotation) does the same. Wait for /health,
# which also checks the database, rather than failing the run.
READY_WAIT = 300

# ReminderUrgency names as the API serializes them (Enum/ReminderUrgency.cs).
# NotUrgent is never requested, so it never posts.
TIERS = ["Urgent", "VeryUrgent", "PastDue"]
LABELS = {"Urgent": "Urgent", "VeryUrgent": "Very urgent", "PastDue": "Past due"}
COLORS = {"Urgent": 0xF1C40F, "VeryUrgent": 0xE67E22, "PastDue": 0xE74C3C}

# Discord rejects a message with more than 10 embeds, a title over 256
# characters, or embeds totalling over 6000 characters. Notes are free
# text, so cap each embed well under 600 and a full message of 10 fits.
EMBEDS_PER_MESSAGE = 10
TITLE_MAX = 100
DESCRIPTION_MAX = 400


def secret(name):
    return (CREDS / name).read_text().strip()


def api_get(path, params):
    user = secret("root_username")
    password = secret("root_password")
    token = base64.b64encode(f"{user}:{password}".encode()).decode()
    query = urllib.parse.urlencode(params, doseq=True)
    req = urllib.request.Request(
        f"{BASE}{path}?{query}" if query else f"{BASE}{path}",
        headers={
            "Authorization": f"Basic {token}",
            # Invariant number/date formatting regardless of the
            # server locale override.
            "culture-invariant": "1",
            "Accept": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        return json.load(resp)


def wait_ready():
    deadline = time.monotonic() + READY_WAIT
    while True:
        try:
            with urllib.request.urlopen(f"{BASE}/health", timeout=TIMEOUT):
                return
        except (urllib.error.URLError, ConnectionError) as e:
            if time.monotonic() > deadline:
                raise SystemExit(f"LubeLogger not ready after {READY_WAIT}s: {e}")
            time.sleep(5)


def post_discord(webhook, embeds):
    body = json.dumps({"username": "LubeLogger", "embeds": embeds}).encode()
    req = urllib.request.Request(
        webhook,
        data=body,
        headers={
            "Content-Type": "application/json",
            # Discord's edge rejects urllib's default User-Agent.
            "User-Agent": "lubelogger-reminder-notify",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=TIMEOUT):
        pass


def vehicle_name(vehicle):
    parts = [str(vehicle.get("year") or ""), vehicle.get("make"), vehicle.get("model")]
    return " ".join(p for p in parts if p) or f"Vehicle {vehicle.get('id')}"


def describe_due(reminder):
    """Human due line: date and/or odometer, per the reminder's own metric."""
    lines = []
    metric = reminder.get("userMetric", "Date")
    if metric in ("Date", "Both"):
        days = int(reminder.get("dueDays") or 0)
        when = (
            f"{-days} days ago"
            if days < 0
            else ("today" if days == 0 else f"in {days} days")
        )
        lines.append(f"Date: {reminder.get('dueDate')} ({when})")
    if metric in ("Odometer", "Both"):
        dist = int(reminder.get("dueDistance") or 0)
        rel = f"{-dist} km over" if dist < 0 else f"{dist} km to go"
        lines.append(f"Odometer: {reminder.get('dueOdometer')} km ({rel})")
    return "\n".join(lines)


def load_state():
    try:
        return json.loads(STATE_FILE.read_text())
    except FileNotFoundError:
        return {}


def save_state(state):
    # Atomic replace so a crash mid-write can't leave a truncated file
    # that would re-post everything on the next run.
    fd, tmp = tempfile.mkstemp(dir=STATE_FILE.parent, prefix=".state.")
    with os.fdopen(fd, "w") as f:
        json.dump(state, f, indent=2, sort_keys=True)
    os.replace(tmp, STATE_FILE)


def main():
    wait_ready()
    vehicles = {str(v["id"]): v for v in api_get("/api/vehicles", {})}
    reminders = api_get("/api/vehicle/reminders/all", {"urgencies": TIERS})

    previous = load_state()
    current = {str(r["id"]): r["urgency"] for r in reminders}
    # What has actually been delivered: start from the previous run's
    # tiers for reminders still urgent (dropping cleared ones), and
    # advance each entry only once its message posts. A failed batch
    # leaves its reminders at their old tier, so the next run retries
    # them and does not repeat the batches that already went out.
    delivered = {rid: previous[rid] for rid in current if rid in previous}
    pending = []
    for r in reminders:
        rid = str(r["id"])
        tier = r["urgency"]
        if previous.get(rid) == tier:
            continue
        vehicle = vehicles.get(str(r["vehicleId"]), {"id": r["vehicleId"]})
        title = f"{LABELS.get(tier, tier)}: {r['description']}"
        desc = describe_due(r)
        if r.get("notes"):
            desc += f"\n\n{r['notes']}"
        pending.append(
            (
                rid,
                tier,
                {
                    "title": title[:TITLE_MAX],
                    "description": desc[:DESCRIPTION_MAX],
                    "color": COLORS.get(tier, 0x95A5A6),
                    "url": f"{PUBLIC_URL}/Vehicle/Index?vehicleId={r['vehicleId']}",
                    "footer": {"text": vehicle_name(vehicle)},
                },
            )
        )

    save_state(delivered)
    for i in range(0, len(pending), EMBEDS_PER_MESSAGE):
        batch = pending[i : i + EMBEDS_PER_MESSAGE]
        post_discord(secret("webhook"), [embed for _, _, embed in batch])
        delivered.update({rid: tier for rid, tier, _ in batch})
        save_state(delivered)
    print(
        f"{len(reminders)} urgent reminder(s), {len(pending)} posted, "
        f"{len(set(previous) - set(current))} cleared"
    )


if __name__ == "__main__":
    try:
        main()
    except urllib.error.HTTPError as e:
        # The URL can carry the webhook token; report status only.
        print(
            f"HTTP {e.code} from {urllib.parse.urlsplit(e.url).netloc}", file=sys.stderr
        )
        sys.exit(1)
