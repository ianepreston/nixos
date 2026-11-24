#!/usr/bin/env python3
"""Live-validation driver for a dev host (#1063).

    validate-host.py --host H [--switch] [--probe CMD]... [--observe DUR]
                     [--interval DUR] [--require-clean] [--local-secrets]
                     [--override-input NAME VALUE]... [--run-dir DIR]

Runs one validation sequence and writes a log per stage plus one JSON evidence
record (no secret contents) into a run directory outside the git checkout:

  admit      refuse unless H's hostSpec sets `validationTarget = true` AND
             `serverEnvironment = "dev"` (fails closed: an unknown host, a
             missing or false marker, null/prod or an eval error all refuse);
             nothing is written and nothing connects before this
  inputs     source SHA and dirty count, the locked nix-secrets rev, the
             effective input overrides, and the expected closure from the
             helper's own `--dry-run` evaluation (no connection)
  preflight  scripts/activate-nixos.sh --preflight; on failure the helper's
             classified message is the result
  pre-state  read-only: running closure, generation, booted closure, system
             state, failed units (each with a state-change mark: the baseline),
             next nixos-upgrade timer; refuses to go on while
             nixos-upgrade.service is running, and with --require-clean while
             any unit has failed or the system is not `running`
  check      the helper's --action check (build + identity, activates nothing)
  switch     only with --switch: the helper's --action switch, which repeats
             its preflight and identity assertions; any error stops the run
  post       running closure/generation (with --switch it must be the expected
             closure), no failed unit that is new or changed state versus the
             baseline (a failure that predates the run is tolerated and
             reported; the system may then be `degraded`, otherwise it must be
             `running`), every --probe exits 0 (probes run on the target).
             --require-clean instead requires `running` and no failed unit
  observe    only with --observe: repeat the post checks every --interval;
             the running closure must not change. The window runs on a clock
             that counts runner suspend (CLOCK_BOOTTIME on Linux,
             CLOCK_MONOTONIC_RAW on macOS); a check that starts, or spends
             suspended, more than its scheduled wait (at most one interval,
             at least 2s) fails the stage (a sleeping laptop), with the
             offending value in `breach`. Wall time is a cross-check only.
             The record holds started_at/finished_at, the elapsed span, the
             largest gap and lateness, slow checks and a cadence warning.
             Known limits: a suspend in the instants between one check
             closing and the next deadline read is not flagged and can
             shorten the window; a wait can overrun a resume by one 1s
             slice; on the time.monotonic fallback (`suspend_aware: false`)
             only wall time shows a suspend, so a backward wall step can
             hide one, and a suspend inside a check is missed where
             time.monotonic counts suspend (see stage_observe)
  evidence   always written, also after a failure: evidence.json

Every host command goes through the helper or through one read-only ssh that
asserts the hostname in the same process. There is no option to skip the
helper's preflight or identity checks, no retry, no rollback and no kill of an
activation: a switch that outlives its deadline is left running and reported as
unknown. A required host read that fails, an ssh that fails or drops before
its nonce marker, and a failing probe each stop the stage with no further
connection. Once admitted, every run ends with evidence.json, including after
a command that could not be launched.

The evidence holds no probe text (only index, a short sha256 id and the exit
code), and every recorded message or input value is scrubbed of $HOME,
URL userinfo, query strings and token-like strings. Exit status: 0 passed,
1 failed, 2 refused/usage, 3 switch outcome unknown (through Go Task, use
`task --exit-code` to see it), 130 interrupted.
"""

import argparse
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import re
import secrets as nonce_source
import shlex
import signal
import subprocess
import sys
import time
import urllib.parse

SCRIPTS = Path(__file__).resolve().parent
REPO = SCRIPTS.parent
HELPER = SCRIPTS / "activate-nixos.sh"
REMOTE = SCRIPTS / "_validate-host" / "remote.sh"
USER = "ipreston"  # the helper's default target user

HOST_RE = re.compile(r"[a-z0-9]([a-z0-9-]*[a-z0-9])?")
CLOSURE_RE = r"/nix/store/[0-9abcdfghijklmnpqrsvwxyz]{32}-nixos-system-%s-[0-9]{2}\.[0-9]{2}[0-9A-Za-z._+-]*"
DURATION_RE = re.compile(r"([0-9]+)([smh]?)")
GENERATION_RE = re.compile(r"(?:.*/)?system-([0-9]+)-link")
SYSTEM_STATES = {
    "initializing",
    "starting",
    "running",
    "degraded",
    "maintenance",
    "stopping",
    "offline",
    "unknown",
}
# InvocationID (`-` when systemd assigned none) and
# StateChangeTimestampMonotonic of a failed unit.
FAILED_UNIT_MARK_RE = re.compile(r"(?:[0-9a-f]{32}|-) [1-9][0-9]*")
UNIT_NAME_RE = re.compile(
    r"[A-Za-z0-9:_.@\\-]+\.(?:service|socket|device|mount|automount|swap|target|path|timer|slice|scope)"
)
# Keys remote.sh can name in `VALIDATE-READ-FAILED <key>`.
READ_KEYS = (
    "current_system",
    "booted_system",
    "system_profile",
    "system_state",
    "failed_units",
    "failed_unit_mark",
    "upgrade_service",
    "upgrade_timer_next",
)
# Single-valued keys of a state read; each must appear at most once.
STATE_KEYS = (
    "hostname",
    "current_system",
    "booted_system",
    "system_profile",
    "system_state",
    "upgrade_service",
    "upgrade_timer_next",
)
# Known token prefixes, or a long run mixing upper case, lower case and digits
# (store hashes and git revisions have no upper case, so they are kept).
TOKEN_RE = re.compile(
    r"(?:gh[pousr]_|github_pat_|glpat-|xox[abprs]-|sk-)[A-Za-z0-9_-]{8,}"
    r"|(?=[A-Za-z0-9_+=-]*[A-Z])(?=[A-Za-z0-9_+=-]*[a-z])"
    r"(?=[A-Za-z0-9_+=-]*[0-9])[A-Za-z0-9_+=-]{24,}"
)
USERINFO_RE = re.compile(r"([A-Za-z][A-Za-z0-9+.-]*://)[^/@\s]*@")
URL_QUERY_RE = re.compile(r"([A-Za-z][A-Za-z0-9+.-]*:[^\s?#'\"]*)[?#][^\s'\"]*")
# git variables that would point `git -C <dir>` at another repository
GIT_REDIRECT_VARS = (
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_COMMON_DIR",
    "GIT_INDEX_FILE",
    "GIT_CEILING_DIRECTORIES",
    "GIT_DISCOVERY_ACROSS_FILESYSTEM",
    "GIT_NAMESPACE",
)

MAX_OBSERVE = 4 * 3600
ADMIT_TIMEOUT = 600
GIT_TIMEOUT = 30
EVAL_TIMEOUT = 900
PREFLIGHT_TIMEOUT = 300
READ_TIMEOUT = 60

# Read-only, non-interactive options placed before anything ssh_config adds
# (OpenSSH keeps the first value). ControlMaster=no reuses an existing master
# from ssh_config (the same one the helper uses) but never becomes one.
SSH_OPTS = [
    "-oBatchMode=yes",
    "-oConnectTimeout=8",
    "-oStrictHostKeyChecking=yes",
    "-oUpdateHostKeys=no",
    "-oAddKeysToAgent=no",
    "-oClearAllForwardings=yes",
    "-oPermitLocalCommand=no",
    "-oForkAfterAuthentication=no",
    "-oRemoteCommand=none",
    "-oControlMaster=no",
]

EXIT_PASS, EXIT_FAIL, EXIT_REFUSED, EXIT_UNKNOWN, EXIT_INTERRUPTED = 0, 1, 2, 3, 130
STAGES = [
    "inputs",
    "preflight",
    "pre-state",
    "check",
    "switch",
    "post",
    "observe",
    "evidence",
]


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")


def span_clock(platform=sys.platform, clocks=time):
    """(name, read) of a monotonic clock that keeps counting while the runner
    is suspended (#1090): CLOCK_BOOTTIME on Linux, CLOCK_MONOTONIC_RAW on
    macOS (where time.monotonic() is mach_absolute_time and stops during
    sleep; Linux's CLOCK_MONOTONIC_RAW stops too, so it is not used there).
    If neither is available or readable: ("monotonic", time.monotonic), the
    fallback stage_observe records as `suspend_aware: false`."""
    if platform.startswith("linux"):
        name = "CLOCK_BOOTTIME"
    elif platform == "darwin":
        name = "CLOCK_MONOTONIC_RAW"
    else:
        return "monotonic", clocks.monotonic
    clock = getattr(clocks, name, None)
    try:
        if clock is None:
            raise OSError
        clocks.clock_gettime(clock)
    except (OSError, ValueError):
        return "monotonic", clocks.monotonic
    return name, lambda: clocks.clock_gettime(clock)


def ceil3(seconds):
    """Rounded up to the millisecond: a value over a tolerance never reads
    as equal to it."""
    return math.ceil(seconds * 1000) / 1000


def wall_iso(seconds):
    return datetime.datetime.fromtimestamp(seconds, datetime.timezone.utc).isoformat(
        timespec="seconds"
    )


# The observe stage's clocks, module-level so the tests can replace them:
# SPAN_CLOCK counts suspend, AWAKE_CLOCK (time.monotonic) does not on Linux
# or macOS, WALL_CLOCK (time.time) is a cross-check only.
SPAN_CLOCK_NAME, SPAN_CLOCK = span_clock()
AWAKE_CLOCK = time.monotonic
WALL_CLOCK = time.time
SLEEP = time.sleep
# A wait is cut into slices this long and the deadline re-read after each:
# time.sleep() itself may not count a suspend, so after a resume it can run
# on for at most one slice.
SLEEP_SLICE = 1.0
# Smallest tolerance for a late or suspended observation check.
MIN_LATE_TOLERANCE = 2


def say(msg):
    print(f"validate-host: {msg}", file=sys.stderr, flush=True)


class Refused(Exception):
    """Refused before anything connected or was written."""


class StageFailed(Exception):
    def __init__(self, summary, exit_code=None, outcome="failed"):
        super().__init__(summary)
        self.summary = summary
        self.exit_code = exit_code
        self.outcome = outcome  # failed | unknown


def launch_failed(argv, err):
    return StageFailed(
        f"cannot launch {Path(str(argv[0])).name}: {err.strerror or type(err).__name__}"
    )


def scrub(text):
    """Strip $HOME, URL userinfo, query strings and token-like material from a
    string that goes into the evidence record."""
    if text is None:
        return None
    text = str(text)
    home = os.path.expanduser("~")
    if home and home != "/":
        text = text.replace(home, "~")
    text = USERINFO_RE.sub(r"\1<redacted>@", text)
    text = URL_QUERY_RE.sub(r"\1?<redacted>", text)
    return TOKEN_RE.sub("<redacted>", text)


def probe_id(command):
    return hashlib.sha256(command.encode()).hexdigest()[:12]


def duration(text):
    m = DURATION_RE.fullmatch(text)
    if not m:
        raise argparse.ArgumentTypeError(
            f"invalid duration {text!r} (use N, Ns, Nm or Nh)"
        )
    return int(m.group(1)) * {"": 1, "s": 1, "m": 60, "h": 3600}[m.group(2)]


class Once(argparse.Action):
    """A single-valued option that may be given only once (so a wrapper's
    --host cannot be overridden by a later one)."""

    def __call__(self, parser, namespace, values, option_string=None):
        if getattr(namespace, self.dest) is not None:
            parser.error(f"{option_string} may be given only once")
        setattr(namespace, self.dest, values)


def parse_args(argv):
    p = argparse.ArgumentParser(
        prog="validate-host.py",
        allow_abbrev=False,
        description="Preflight, check, optionally switch, probe and observe a dev host.",
    )
    p.add_argument("--host", action=Once, required=True)
    p.add_argument(
        "--switch", action="store_true", help="activate (default: check only)"
    )
    p.add_argument(
        "--probe",
        action="append",
        default=[],
        metavar="CMD",
        help="command run on the target after the switch and while observing (repeatable)",
    )
    p.add_argument(
        "--observe",
        action=Once,
        type=duration,
        metavar="DUR",
        help="observation window after the post checks (e.g. 3m)",
    )
    p.add_argument(
        "--interval",
        action=Once,
        type=duration,
        metavar="DUR",
        help="observation check interval (default 30s)",
    )
    p.add_argument("--probe-timeout", action=Once, type=duration, metavar="DUR")
    p.add_argument(
        "--build-timeout",
        action=Once,
        type=duration,
        metavar="DUR",
        help="deadline for --action check (default 2h)",
    )
    p.add_argument(
        "--switch-timeout",
        action=Once,
        type=duration,
        metavar="DUR",
        help="deadline for the switch; on expiry it is left running (default 2h)",
    )
    p.add_argument(
        "--require-clean",
        action="store_true",
        help="fail on any failed unit or a non-running system, even one that predates this run",
    )
    p.add_argument("--local-secrets", action="store_true")
    p.add_argument(
        "--override-input",
        nargs=2,
        action="append",
        default=[],
        metavar=("NAME", "VALUE"),
    )
    p.add_argument("--run-dir", action=Once, type=Path)
    a = p.parse_args(argv)
    a.observe = 0 if a.observe is None else a.observe
    a.interval = 30 if a.interval is None else a.interval
    a.probe_timeout = 60 if a.probe_timeout is None else a.probe_timeout
    a.build_timeout = 7200 if a.build_timeout is None else a.build_timeout
    a.switch_timeout = 7200 if a.switch_timeout is None else a.switch_timeout
    if a.observe > MAX_OBSERVE:
        p.error(f"--observe is capped at {MAX_OBSERVE}s")
    # Checked as ints, so an absurd value is refused before stage_observe's
    # float arithmetic could overflow. Only the observe options are capped.
    if a.interval > MAX_OBSERVE:
        p.error(f"--interval is capped at {MAX_OBSERVE}s")
    if (
        a.interval < 1
        or a.probe_timeout < 1
        or a.build_timeout < 1
        or a.switch_timeout < 1
    ):
        p.error("durations must be at least 1s")
    for probe in a.probe:
        if not probe.strip():
            p.error("--probe needs a command")
    return a


def child_env():
    env = {
        k: v
        for k, v in os.environ.items()
        if k != "NIX_SSHOPTS" and k not in GIT_REDIRECT_VARS
    }
    env.update(LC_ALL="C", SSH_ASKPASS_REQUIRE="never")
    return env


def stop_group(proc):
    """Terminate a non-activating child and everything it spawned."""
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(proc.pid, sig)
        except ProcessLookupError:
            return
        try:
            proc.wait(5)
            return
        except subprocess.TimeoutExpired:
            continue


def log_safe_state(out):
    """Stdout of a state read as it may be logged: a failed_unit or
    failed_unit_mark line that does not validate is replaced by a diagnostic,
    so a rejected payload never reaches the stage log."""
    lines = []
    for line in out.decode(errors="replace").split("\n"):
        key, sep, value = line.partition("=")
        if sep and key == "failed_unit" and not UNIT_NAME_RE.fullmatch(value):
            line = "failed_unit=<malformed unit name withheld>"
        elif sep and key == "failed_unit_mark":
            unit, _, mark = value.partition(" ")
            if not (
                UNIT_NAME_RE.fullmatch(unit) and FAILED_UNIT_MARK_RE.fullmatch(mark)
            ):
                shown = unit if UNIT_NAME_RE.fullmatch(unit) else "<unit withheld>"
                line = f"failed_unit_mark={shown} <malformed mark withheld>"
        lines.append(line)
    return "\n".join(lines).encode()


def run_capture(argv, timeout, stdin_text=None, log=None, log_filter=None):
    """Run a bounded, non-activating command. Returns (rc, stdout); rc is None
    on timeout. stderr (and, when given, stdout, passed through `log_filter`)
    is appended to `log`."""
    sink = open(log, "ab") if log else subprocess.DEVNULL
    try:
        if log:
            sink.write(f"$ {shlex.join(map(str, argv))}\n".encode())
            sink.flush()
        try:
            proc = subprocess.Popen(
                argv,
                stdin=subprocess.PIPE if stdin_text is not None else subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=sink,
                env=child_env(),
                start_new_session=True,
            )
        except (OSError, ValueError) as e:
            if log:
                sink.write(f"[cannot launch: {e}]\n".encode())
            raise launch_failed(argv, e) from None
        try:
            out, _ = proc.communicate(
                stdin_text.encode() if stdin_text is not None else None, timeout
            )
        except subprocess.TimeoutExpired:
            stop_group(proc)
            if log:
                sink.write(f"[timed out after {timeout}s]\n".encode())
            return None, ""
        except BaseException:
            stop_group(proc)
            raise
        if log:
            sink.write(log_filter(out) if log_filter else out)
            sink.write(f"[exit {proc.returncode}]\n".encode())
        return proc.returncode, out.decode(errors="replace")
    finally:
        if log:
            sink.close()


def run_logged(argv, log, timeout, activation=False):
    """Run the helper with all output in `log`. Returns its exit status, or
    None on timeout. An activation is never signalled: on expiry it is left
    running (in its own session) and the caller reports the outcome unknown."""
    with open(log, "ab") as sink:
        sink.write(f"$ {shlex.join(map(str, argv))}\n".encode())
        sink.flush()
        try:
            proc = subprocess.Popen(
                argv,
                stdin=subprocess.DEVNULL,
                stdout=sink,
                stderr=subprocess.STDOUT,
                env=child_env(),
                start_new_session=True,
            )
        except (OSError, ValueError) as e:
            sink.write(f"[cannot launch: {e}]\n".encode())
            raise launch_failed(argv, e) from None
        try:
            rc = proc.wait(timeout)
        except subprocess.TimeoutExpired:
            if activation:
                sink.write(
                    f"[deadline {timeout}s passed; pid {proc.pid} left running]\n".encode()
                )
                return None, proc.pid
            stop_group(proc)
            sink.write(f"[timed out after {timeout}s]\n".encode())
            return None, proc.pid
        except BaseException:
            if not activation:
                stop_group(proc)
            raise
        sink.write(f"[exit {rc}]\n".encode())
        return rc, proc.pid


def last_message(log, prefixes):
    """The helper's last classified line, for the stage summary."""
    try:
        lines = Path(log).read_text(errors="replace").splitlines()
    except OSError:
        return None
    for line in reversed(lines):
        if line.startswith(prefixes):
            return line
    return None


# Flake-ref forms whose path names a repository, not a credential: they keep
# their (scrubbed) location. Any other URL keeps only scheme + origin.
SAFE_REF_PREFIXES = (
    "github:",
    "gitlab:",
    "sourcehut:",
    "path:",
    "git+ssh://",
    "git+file:",
    "file:",
    "/",
)
SAFE_REV_RE = re.compile(r"[0-9a-f]{7,40}")
SAFE_REF_RE = re.compile(r"[A-Za-z0-9._/-]{1,100}")


def input_fingerprint(value):
    return hashlib.sha256(str(value).encode()).hexdigest()[:12]


def mask_forms(value):
    """The forms an override value can take in a diagnostic. The original URL
    is parsed once; its components (authority, password, host, path, query,
    fragment) are decoded separately, never re-parsed after decoding."""
    unquote = urllib.parse.unquote
    base = value.partition("?")[0].partition("#")[0]
    forms = {value, unquote(value), base, unquote(base)}
    parts = urllib.parse.urlsplit(value)
    userinfo, at, hostport = parts.netloc.rpartition("@")
    password = userinfo.partition(":")[2] if at else ""
    for component in (parts.netloc, hostport, password, parts.path, parts.query, parts.fragment):  # fmt: skip
        forms.update({component, unquote(component)})
    return forms


def input_masks(overrides):
    """(form, marker) pairs, longest form first, for every override value.
    Each occurrence becomes `<input:NAME FP>`. Building them can never abort a
    run: if a value cannot be taken apart, only its raw form is masked."""
    masks = {}
    for name, value in overrides:
        value = str(value)
        marker = f"<input:{name} {input_fingerprint(value)}>"
        try:
            forms = mask_forms(value)
        except Exception:  # noqa: BLE001 - malformed input: raw value only
            forms = {value}
        for form in forms:
            if len(form) >= 4 and form not in masks:
                masks[form] = marker
    return sorted(masks.items(), key=lambda kv: -len(kv[0]))


def describe_input(name, value):
    """An input override for the evidence: its location without query,
    fragment, userinfo or (for unrecognised URLs) path; safe `rev`/`ref`
    values as separate fields; and a short sha256 fingerprint of the full
    value, so different pins stay distinguishable without being recorded."""
    value = str(value)
    base = value.partition("?")[0].partition("#")[0]
    query = value.partition("?")[2].partition("#")[0]
    rec = {"name": name, "fingerprint": input_fingerprint(value)}
    if base.startswith(SAFE_REF_PREFIXES) or "://" not in base:
        rec["value"] = scrub(base)
    else:
        scheme = base.partition("://")[0]
        try:
            parts = urllib.parse.urlsplit(base)
            origin = parts.hostname or ""
            port = parts.port
            rec["value"] = f"{parts.scheme}://{origin}" + (f":{port}" if port else "")
        except ValueError:  # malformed authority (e.g. an unbalanced bracket)
            rec["value"] = scrub(f"{scheme}://<unparsable>")
    params = urllib.parse.parse_qs(query, keep_blank_values=False)
    rev = (params.get("rev") or [None])[-1]
    if rev and SAFE_REV_RE.fullmatch(rev):
        rec["rev"] = rev
    ref = (params.get("ref") or [None])[-1]
    if ref and SAFE_REF_RE.fullmatch(ref) and not TOKEN_RE.search(ref):
        rec["ref"] = ref
    return rec


def units_text(units, limit=10):
    shown = ", ".join(units[:limit])
    return shown + (f", ... (+{len(units) - limit})" if len(units) > limit else "")


def compare_failed_units(baseline, state):
    """Failed units in `state` against the pre-state `baseline`:

      new        failing now, not failing in the baseline
      changed    failing in both, but its mark (InvocationID + last state
                 change) differs or is unreadable: it failed again since
      tolerated  failing in both with the same, well-formed mark
      cleared    failing in the baseline, not now

    Fails closed: a unit without a well-formed mark in either snapshot is
    never tolerated."""
    base_marks = baseline.get("failed_unit_marks", {})
    marks = state.get("failed_unit_marks", {})
    new, changed, tolerated = [], [], []
    for unit in state["failed_units"]:
        if unit not in baseline["failed_units"]:
            new.append(unit)
        elif (
            FAILED_UNIT_MARK_RE.fullmatch(base_marks.get(unit, ""))
            and marks.get(unit) == base_marks[unit]
        ):
            tolerated.append(unit)
        else:
            changed.append(unit)
    current = set(state["failed_units"])
    return {
        "baseline": list(baseline["failed_units"]),
        "new": new,
        "changed": changed,
        "tolerated": tolerated,
        "cleared": [u for u in baseline["failed_units"] if u not in current],
    }


# Reads only the two admission fields; a hostSpec without the marker yields
# null, which refuses like false.
ADMIT_APPLY = "s: { serverEnvironment = s.serverEnvironment or null; validationTarget = s.validationTarget or null; }"


def admit(host):
    """Fail closed unless the flake's hostSpec marks this host as a validation
    target (`validationTarget = true`) and it is a dev server. Returns the
    admitted fields."""
    if not HOST_RE.fullmatch(host):
        raise Refused(f"invalid host name {host!r}")
    attr = f"{REPO}#nixosConfigurations.{host}._module.specialArgs.hostSpec"
    try:
        rc, out = run_capture(
            ["nix", "eval", "--json", attr, "--apply", ADMIT_APPLY], ADMIT_TIMEOUT
        )
    except StageFailed as e:
        raise Refused(f"refusing {host}: {e.summary}") from None
    if rc != 0:
        raise Refused(
            f"refusing {host}: no nixosConfigurations.{host} hostSpec could be evaluated (unknown host?)"
        )
    try:
        spec = json.loads(out)
    except ValueError:
        spec = None
    if not isinstance(spec, dict):
        raise Refused(f"refusing {host}: unreadable hostSpec admission fields")
    marker, env = spec.get("validationTarget"), spec.get("serverEnvironment")
    if marker is not True:
        raise Refused(
            f"refusing {host}: hostSpec validationTarget is {json.dumps(marker)}; only hosts marked `validationTarget = true` may be validated"
        )
    if env != "dev":
        raise Refused(
            f'refusing {host}: serverEnvironment is {json.dumps(env)}, only "dev" hosts may be validated'
        )
    return {"server_environment": env, "validation_target": True}


def default_run_dir(host):
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(
        os.path.expanduser("~"), ".local", "state"
    )
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return Path(base) / "nixos-validate" / host / f"{stamp}-{os.getpid()}"


def git_membership(directory):
    """'inside', 'outside' or an error string for an existing directory, asked
    of git itself (fails closed: anything but "not a git repository" counts as
    a reason to refuse)."""
    try:
        r = subprocess.run(
            ["git", "-C", str(directory), "rev-parse", "--git-dir"],
            # Cross mount points, so a volume mounted inside a checkout still
            # counts as inside it.
            env={**child_env(), "GIT_DISCOVERY_ACROSS_FILESYSTEM": "1"},
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=GIT_TIMEOUT,
        )
    except (OSError, subprocess.TimeoutExpired) as e:
        return f"cannot ask git ({type(e).__name__})"
    if r.returncode == 0:
        return "inside"
    if "not a git repository" in r.stderr.lower():
        return "outside"
    return f"git rev-parse failed (exit {r.returncode})"


def make_run_dir(path):
    path = Path(os.path.abspath(path))
    repo = REPO.resolve()
    resolved = path.resolve()
    if resolved == repo or repo in resolved.parents:
        raise Refused(
            f"run directory {path} is inside the checkout; logs stay outside git"
        )
    # Any Git repository or work tree (another checkout, the primary checkout,
    # a dotfiles repo at $HOME, ...) is refused, judged from the deepest
    # ancestor that already exists, before anything is created.
    ancestor = resolved
    while not ancestor.exists():
        ancestor = ancestor.parent
    if not ancestor.is_dir():
        raise Refused(f"run directory {path}: {ancestor} is not a directory")
    membership = git_membership(ancestor)
    if membership == "inside":
        raise Refused(
            f"run directory {path} is inside a Git repository ({ancestor}); logs stay outside git"
        )
    if membership != "outside":
        raise Refused(f"run directory {path}: {membership}; refusing")
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.mkdir(mode=0o700)
    except FileExistsError:
        raise Refused(f"run directory {path} already exists") from None
    except OSError as e:
        raise Refused(f"cannot create run directory {path}: {e.strerror}") from None
    return path


class Validation:
    def __init__(self, args, admitted, run_dir):
        self.a = args
        self.host = args.host
        self.target = f"{USER}@{args.host}"
        self.run_dir = run_dir
        self.input_flags = ["--local-secrets"] if args.local_secrets else []
        for name, value in args.override_input:
            self.input_flags += ["--override-input", name, value]
        self.closure_re = re.compile(CLOSURE_RE % re.escape(self.host))
        self.input_masks = input_masks(args.override_input)
        self.stages = {
            name: {"name": name, "status": "not-run", "log": None} for name in STAGES
        }
        self.evidence = {
            "schema": "nixos-validate-host/3",
            "host": self.host,
            "target": self.target,
            "server_environment": admitted["server_environment"],
            "validation_target": admitted["validation_target"],
            "switch_requested": args.switch,
            "require_clean": args.require_clean,
            "run_dir": str(run_dir),
            "started_at": now(),
            "finished_at": None,
            "result": None,
            "failed_stage": None,
            "message": None,
            "source": None,
            "inputs": None,
            "expected_closure": None,
            "pre": None,
            "post": None,
            "generation_changed": None,
            "failed_units": None,
            "probes": [],
            "observe": None,
            "stages": [],
        }

    # --- plumbing -------------------------------------------------------------
    def clean(self, text):
        """Evidence/summary text: every known override value masked, then the
        general scrub."""
        if text is None:
            return None
        text = str(text)
        for form, marker in self.input_masks:
            text = text.replace(form, marker)
        return scrub(text)

    def helper_message(self, log, prefixes):
        """The helper's last classified diagnostic, safe for the evidence. A
        line that names an override (the helper echoes a rejected
        `NAME=VALUE` verbatim) is never copied: only the input names and
        fingerprints are reported; the full text stays in the local log."""
        line = last_message(log, prefixes)
        if line is None:
            return None
        masked = self.clean(line)
        hits = sorted(set(re.findall(r"<input:[^ >]+ [0-9a-f]{12}>", masked)))
        if hits:
            return f"helper diagnostic concerns override input {', '.join(hits)}; details in the local stage log"
        if "override" in line:
            return "helper rejected an override input; details in the local stage log"
        return masked

    def log(self, stage):
        return self.run_dir / f"{STAGES.index(stage) + 1:02d}-{stage}.log"

    def helper(self, *extra):
        return [
            "bash",
            str(HELPER),
            "--host",
            self.host,
            "--dest",
            self.host,
            *self.input_flags,
            *extra,
        ]

    def remote(self, stage, command, timeout, log_filter=None, reads=False):
        """One read-only ssh to the target; the script asserts the hostname
        before anything else. Returns stdout lines."""
        nonce = nonce_source.token_hex(16)
        script = REMOTE.read_text() + command(nonce) + "\n"
        argv = [
            "ssh",
            *SSH_OPTS,
            "-T",
            self.target,
            "bash",
            "-s",
            "--",
            self.host,
            nonce,
        ]
        rc, out = run_capture(
            argv, timeout, stdin_text=script, log=self.log(stage), log_filter=log_filter
        )
        lines = out.splitlines()
        if rc is None:
            raise StageFailed(f"read from {self.target} timed out after {timeout}s")
        if "VALIDATE-WRONG-HOST" in lines:
            raise StageFailed(
                f"{self.target} did not report hostname {self.host}; stopping (inspect the ssh route)",
                rc,
            )
        # Only a state read can report a failed read. The key is matched
        # against a fixed list and never copied: the persisted text comes
        # from this file, not from remote output (a probe can print anything).
        if reads:
            failed = [
                line.split()[1:2]
                for line in lines
                if line.split()[:1] == ["VALIDATE-READ-FAILED"]  # fmt: skip
            ]
            if failed:
                key = next((k for k in READ_KEYS if [k] == failed[0]), None)
                raise StageFailed(
                    f"required read '{key}' failed on {self.host}; stopping"
                    if key
                    else f"a required read failed on {self.host} (unrecognised key); stopping",
                    rc,
                )
        # A marker alone is not enough: ssh itself must succeed too.
        if rc != 0:
            raise StageFailed(
                f"ssh to {self.target} failed (exit {rc}); stopping, no further connections",
                rc,
            )
        return rc, lines, nonce

    def read_state(self, stage):
        rc, lines, nonce = self.remote(
            stage,
            lambda _n: "state",
            READ_TIMEOUT,
            log_filter=log_safe_state,
            reads=True,
        )
        # The snapshot is everything before its one end marker; a missing or
        # repeated marker, or any output after it, makes it ambiguous.
        end = [i for i, line in enumerate(lines) if line == f"VALIDATE-END {nonce}"]
        if len(end) != 1:
            raise StageFailed(
                f"state read from {self.target} did not complete (exit {rc})", rc
            )
        if any(line.strip() for line in lines[end[0] + 1 :]):
            raise StageFailed(
                f"state read from {self.target} has output after its end marker; stopping"
            )
        state = {"failed_units": [], "failed_unit_marks": {}}
        for line in lines[: end[0]]:
            key, sep, value = line.partition("=")
            if not sep:
                continue
            # Exactly one record per unit and one value per key; a unit name
            # or mark that does not validate is never stored (no arbitrary
            # text reaches the evidence). Anything else fails the read.
            if key == "failed_unit":
                if not UNIT_NAME_RE.fullmatch(value) or value in state["failed_units"]:
                    raise StageFailed(
                        f"failed-unit list read from {self.host} is malformed or repeats a unit; stopping"
                    )
                state["failed_units"].append(value)
            elif key == "failed_unit_mark":
                unit, _, mark = value.partition(" ")
                if not (
                    UNIT_NAME_RE.fullmatch(unit) and FAILED_UNIT_MARK_RE.fullmatch(mark)
                ):
                    raise StageFailed(
                        f"failed-unit mark read from {self.host} is malformed; stopping"
                    )
                if unit in state["failed_unit_marks"]:
                    raise StageFailed(
                        f"failed-unit mark read from {self.host} repeats a unit; stopping"
                    )
                state["failed_unit_marks"][unit] = mark
            elif key in STATE_KEYS:
                if key in state:
                    raise StageFailed(
                        f"{key} read from {self.host} is repeated; stopping"
                    )
                state[key] = value
        # Every value is required and must parse: an empty or malformed read
        # can never stand in for a baseline (two empty values would compare
        # equal).
        for key in ("current_system", "booted_system"):
            if not self.closure_re.fullmatch(state.get(key, "")):
                raise StageFailed(
                    f"{key} read from {self.host} is not a nixos-system-{self.host} closure; stopping"
                )
        m = GENERATION_RE.fullmatch(state.get("system_profile", ""))
        if not m:
            raise StageFailed(
                f"system profile generation read from {self.host} is unparsable; stopping"
            )
        state["generation"] = int(m.group(1))
        if state.get("system_state") not in SYSTEM_STATES:
            raise StageFailed(
                f"system state read from {self.host} is unrecognised; stopping"
            )
        if not state.get("upgrade_service") or "upgrade_timer_next" not in state:
            raise StageFailed(
                f"nixos-upgrade read from {self.host} is incomplete; stopping"
            )
        # Every failed unit needs exactly one mark, and no mark may name a
        # unit that is not listed: an incomplete set is never a baseline.
        if set(state["failed_unit_marks"]) != set(state["failed_units"]):
            raise StageFailed(
                f"failed-unit marks read from {self.host} are incomplete; stopping"
            )
        state["failed_unit_count"] = len(state["failed_units"])
        state["read_at"] = now()
        return state

    def unit_problems(self, stage, state):
        """Failed units and system state against the pre-state baseline. The
        comparison is stored in the evidence; returns the problems."""
        report = compare_failed_units(self.evidence["pre"], state)
        report["stage"] = stage
        self.evidence["failed_units"] = report
        problems = []
        system_state = state["system_state"]
        if self.a.require_clean:
            if system_state != "running":
                problems.append(f"system state is {system_state!r}, not 'running' (--require-clean)")  # fmt: skip
            if state["failed_unit_count"]:
                problems.append(
                    f"{state['failed_unit_count']} failed unit(s) (--require-clean): {units_text(state['failed_units'])}"
                )
            return problems
        if report["new"]:
            problems.append(
                f"{len(report['new'])} new failed unit(s) since pre-state: {units_text(report['new'])}"
            )
        if report["changed"]:
            problems.append(
                f"{len(report['changed'])} pre-existing failed unit(s) changed state since pre-state: {units_text(report['changed'])}"
            )
        # `degraded` means at least one failed unit, so the unit comparison
        # above decides it; degraded with no failed unit listed is a problem.
        if system_state == "degraded" and state["failed_unit_count"]:
            if not problems and stage != "observe":
                self.warn_tolerated(stage, report["tolerated"])
        elif system_state != "running":
            problems.append(f"system state is {system_state!r}, not 'running'")
        return problems

    def warn_tolerated(self, stage, units):
        say(
            f"WARNING: {stage}: {len(units)} failed unit(s) predate this run and are tolerated "
            f"(--require-clean fails on them): {units_text(units)}"
        )

    def run_probe(self, stage, index, probe):
        """The probe's exit status. Any transport failure (ssh error, a
        dropped connection before the marker) raises and ends the stage."""

        def command(nonce):
            delim = f"VALIDATE_PROBE_EOF_{nonce}"
            return f"probe <<'{delim}'\n{probe}\n{delim}"

        rc, lines, nonce = self.remote(stage, command, self.a.probe_timeout)
        prefix = f"VALIDATE-PROBE-RC {nonce} "
        codes = [
            int(x[len(prefix) :])
            for x in lines
            if x.startswith(prefix) and x[len(prefix) :].isdigit()
        ]
        if not codes:
            raise StageFailed(
                f"probe #{index} did not report its exit status (ssh exit {rc}); stopping, no further connections",
                rc,
            )
        return codes[-1]

    def health(self, stage, probes, on_state=None):
        """The post/observe checks; probe results are appended to `probes` as
        they complete. `on_state(state)` runs before the first probe
        connection (so a later transport failure cannot discard the verified
        snapshot) and returns extra problems. Returns (state, problems). The
        first failing probe ends the probing (no further connections)."""
        state = self.read_state(stage)
        problems = list(on_state(state)) if on_state else []
        problems += self.unit_problems(stage, state)
        for index, probe in enumerate(self.a.probe, 1):
            record = {"index": index, "id": probe_id(probe), "exit_code": None}
            probes.append(record)
            record["exit_code"] = self.run_probe(stage, index, probe)
            if record["exit_code"] != 0:
                problems.append(
                    f"probe #{index} (id {record['id']}) exited {record['exit_code']}"
                )
                break
        return state, problems

    def resolve_local_secrets(self, log):
        """The checkout activate-nixos.sh --local-secrets would use, found the
        same way (read-only): $NIX_SECRETS_PATH, then ../nix-secrets beside
        this checkout, then beside the primary checkout of a linked worktree."""
        explicit = os.environ.get("NIX_SECRETS_PATH")
        if explicit:
            if not os.path.isdir(explicit):
                raise StageFailed("NIX_SECRETS_PATH is not a directory")
            return Path(os.path.abspath(explicit))
        cand = REPO / ".." / "nix-secrets"
        if cand.is_dir():
            return Path(os.path.abspath(cand))
        rc, common = run_capture(
            [
                "git",
                "-C",
                str(REPO),
                "rev-parse",
                "--path-format=absolute",
                "--git-common-dir",
            ],
            GIT_TIMEOUT,
            log=log,
        )
        if rc == 0 and common.strip():
            cand = Path(common.strip()) / ".." / ".." / "nix-secrets"
            if cand.is_dir():
                return Path(os.path.abspath(cand))
        raise StageFailed(
            "cannot find the nix-secrets checkout --local-secrets would use (set NIX_SECRETS_PATH or use a sibling ../nix-secrets)"
        )

    def local_secrets_record(self, locked, log):
        """Path (home-relative), HEAD and dirty counts of the local override,
        so different effective inputs never yield the same record."""
        path = self.resolve_local_secrets(log)
        rc, head = run_capture(
            ["git", "-C", str(path), "rev-parse", "--verify", "HEAD"],
            GIT_TIMEOUT,
            log=log,
        )
        head = head.strip()
        if rc != 0 or not re.fullmatch(r"[0-9a-f]{40}", head):
            raise StageFailed("cannot read the local nix-secrets HEAD revision")
        rc, status = run_capture(
            [
                "git",
                "--no-optional-locks",
                "-C",
                str(path),
                "status",
                "--porcelain",
                "--untracked-files=normal",
            ],
            GIT_TIMEOUT,
        )
        if rc != 0:
            raise StageFailed("cannot read the local nix-secrets worktree status")
        dirty = [x for x in status.splitlines() if x.strip()]
        return {
            "path": scrub(str(path)),
            "head": head,
            "dirty": bool(dirty),
            "dirty_paths": len(dirty),
            "matches_lock": head == locked,
        }

    # --- stages ---------------------------------------------------------------
    def stage_inputs(self):
        log = self.log("inputs")
        rc, sha = run_capture(
            ["git", "-C", str(REPO), "rev-parse", "--verify", "HEAD"],
            GIT_TIMEOUT,
            log=log,
        )
        if rc != 0 or not re.fullmatch(r"[0-9a-f]{40}", sha.strip()):
            raise StageFailed("cannot read the source SHA (git rev-parse HEAD)", rc)
        rc, status = run_capture(
            [
                "git",
                "-C",
                str(REPO),
                "status",
                "--porcelain",
                "--untracked-files=normal",
            ],
            GIT_TIMEOUT,
        )
        if rc != 0:
            raise StageFailed("cannot read the worktree status", rc)
        dirty = [x for x in status.splitlines() if x.strip()]
        self.evidence["source"] = {
            "sha": sha.strip(),
            "dirty": bool(dirty),
            "dirty_paths": len(dirty),
        }
        try:
            lock = json.loads((REPO / "flake.lock").read_text())
            node = lock["nodes"][lock["root"]]["inputs"]["nix-secrets"]
            locked = lock["nodes"][node]["locked"]["rev"]
        except (OSError, ValueError, KeyError, TypeError):
            raise StageFailed(
                "cannot read the locked nix-secrets revision from flake.lock"
            ) from None
        self.evidence["inputs"] = {
            "nix_secrets_locked_rev": locked,
            "local_secrets": (
                self.local_secrets_record(locked, log) if self.a.local_secrets else None
            ),
            "override_inputs": [describe_input(n, v) for n, v in self.a.override_input],
        }
        rc, _ = run_logged(self.helper("--dry-run"), log, EVAL_TIMEOUT)
        if rc != 0:
            raise StageFailed(
                self.helper_message(log, ("activate-nixos:",))
                or f"helper --dry-run failed (exit {rc})",
                rc,
            )
        closure = None
        for line in Path(log).read_text(errors="replace").splitlines():
            m = re.fullmatch(r"plan: host=(\S+) action=\S+ closure=(\S+)", line)
            if m and m.group(1) == self.host:
                closure = m.group(2)
        if not closure or not self.closure_re.fullmatch(closure):
            raise StageFailed(
                "helper --dry-run did not report a nixos-system closure for this host"
            )
        self.evidence["expected_closure"] = closure
        return f"source {sha.strip()[:12]}, expected {closure}"

    def stage_preflight(self):
        log = self.log("preflight")
        rc, _ = run_logged(self.helper("--preflight"), log, PREFLIGHT_TIMEOUT)
        if rc != 0:
            msg = self.helper_message(log, ("preflight:", "activate-nixos:"))
            raise StageFailed(
                msg
                or (
                    "preflight timed out"
                    if rc is None
                    else f"preflight failed (exit {rc})"
                ),
                rc,
            )
        return self.helper_message(log, ("preflight: passed",)) or "passed"

    def stage_pre_state(self):
        state = self.read_state("pre-state")
        self.evidence["pre"] = state
        if state.get("upgrade_service") in ("active", "activating", "reloading"):
            raise StageFailed(
                f"nixos-upgrade.service is {state['upgrade_service']} on {self.host}; host state is changing, not validating"
            )
        summary = f"generation {state['generation']}, {state.get('system_state')}, {state['failed_unit_count']} failed"
        if self.a.require_clean:
            problems = []
            if state["system_state"] != "running":
                problems.append(f"system state is {state['system_state']!r}, not 'running'")  # fmt: skip
            if state["failed_unit_count"]:
                problems.append(
                    f"{state['failed_unit_count']} failed unit(s) before the change: {units_text(state['failed_units'])}"
                )
            if problems:
                self.evidence["failed_units"] = {
                    "baseline": list(state["failed_units"]),
                    "new": [],
                    "changed": [],
                    "tolerated": [],
                    "cleared": [],
                    "stage": "pre-state",
                }
                raise StageFailed(
                    "--require-clean: "
                    + "; ".join(problems)
                    + "; not checking or switching"
                )
        elif state["failed_unit_count"]:
            self.warn_tolerated("pre-state", state["failed_units"])
            summary += f" (baseline, tolerated unless new or changed: {units_text(state['failed_units'])})"
        return summary

    def stage_check(self):
        log = self.log("check")
        rc, _ = run_logged(self.helper("--action", "check"), log, self.a.build_timeout)
        if rc != 0:
            msg = self.helper_message(
                log, ("preflight:", "activate-nixos:", "activate:")
            )
            raise StageFailed(
                msg
                or ("check timed out" if rc is None else f"check failed (exit {rc})"),
                rc,
            )
        return "identity check passed"

    def stage_switch(self):
        log = self.log("switch")
        # The check build can take long: re-read just before activating.
        guard = self.read_state("switch")
        pre = self.evidence["pre"]
        if guard.get("upgrade_service") in ("active", "activating", "reloading"):
            raise StageFailed(
                f"nixos-upgrade.service is {guard['upgrade_service']}; not switching"
            )
        if guard.get("current_system") != pre.get("current_system") or guard.get(
            "generation"
        ) != pre.get("generation"):
            raise StageFailed(
                "the running system changed since pre-state; not switching (reconcile first)"
            )
        say(f"switching {self.host} (log {log})")
        rc, pid = run_logged(
            self.helper("--action", "switch"),
            log,
            self.a.switch_timeout,
            activation=True,
        )
        if rc is None:
            raise StageFailed(
                f"switch passed its {self.a.switch_timeout}s deadline and was left running (pid {pid}); outcome unknown, inspect {self.host} before doing anything else",
                outcome="unknown",
            )
        if rc != 0:
            msg = self.helper_message(
                log, ("preflight:", "activate-nixos:", "activate:")
            )
            raise StageFailed(
                f"{msg or f'switch failed (exit {rc})'}; not retried, inspect {self.host}",
                rc,
            )
        return "switch completed"

    def stage_post(self):
        probes = self.evidence["probes"] = []
        state, problems = self.health("post", probes, self.record_post)
        if problems:
            raise StageFailed("; ".join(problems))
        tolerated = self.evidence["failed_units"]["tolerated"]
        health = (
            f"{state['system_state']} with {len(tolerated)} pre-existing failed unit(s) tolerated ({units_text(tolerated)})"
            if tolerated
            else state["system_state"]
        )
        return (
            f"generation {state['generation']}, {health}, {len(probes)} probe(s) passed"
        )

    def record_post(self, state):
        """Store the verified post snapshot and the generation comparison in
        the evidence, and return the closure/generation problems."""
        problems = []
        self.evidence["post"] = state
        pre, expected = self.evidence["pre"], self.evidence["expected_closure"]
        if self.a.switch:
            if state.get("current_system") != expected:
                problems.insert(
                    0,
                    f"running closure {state.get('current_system')!r} is not the expected {expected}",
                )
            if pre.get("current_system") != expected and not (
                state["generation"] is not None
                and pre.get("generation") is not None
                and state["generation"] > pre["generation"]
            ):
                problems.insert(
                    0,
                    f"system generation did not advance ({pre.get('generation')} -> {state['generation']})",
                )
        elif state.get("current_system") != pre.get("current_system"):
            problems.insert(
                0, "the running system changed without a switch from this run"
            )
        if pre.get("generation") is not None and state["generation"] is not None:
            self.evidence["generation_changed"] = (
                state["generation"] != pre["generation"]
            )
        return problems

    def stage_observe(self):
        """Repeat the post checks every interval until the window ends (#1090).

        The window, the waits and every recorded span run on SPAN_CLOCK, which
        counts runner suspend. Check n is due `min(n * interval, window)`
        after the window starts, or as soon as check n-1 ends if that ran
        past that time. Its tolerance is the wait it was scheduled for, from
        the end of check n-1 (or the window start) to that due time: at most
        one interval, at least MIN_LATE_TOLERANCE. So a check left no wait by
        a slow predecessor gets only the minimum. The stage fails closed,
        before running the check, when a check starts more than that after it
        was due, and after the check when it spent more than that suspended
        (its SPAN_CLOCK span beyond its AWAKE_CLOCK time); `breach` then
        holds the offending value. An awake but slow check (`slow_checks`,
        `max_check_s`) and a gap between check starts more than half an
        interval beyond the expected cadence (`cadence_warning`, e.g. two tolerated
        delays in a row) are recorded, never a failure. Timing fields are
        updated on every exit path.

        Wall time is a cross-check only: a step is recorded (`wall_skew_s`,
        `wall_step`) and warned about, and never changes the verdict or the
        span; `finished_at` is the wall clock read at the end, clamped to
        `started_at` (and `wall_step` set) if the clock stepped back past it.
        The exception is the fallback (`suspend_aware: false`, SPAN_CLOCK is
        time.monotonic), where wall time is the only suspend signal.

        Known limits (not detected, by design of the measurement):
        - A suspend in the few instructions between closing one check and
          the next deadline read lies outside every timed segment. With a
          suspend-aware clock it still counts toward the window, so it can
          shorten the observed window without being flagged.
        - time.sleep() may itself pause during a suspend; after resume a wait
          runs on for at most one SLEEP_SLICE before the deadline is re-read.
        - On the fallback, a backward wall step can hide a suspend, and a
          suspend inside a check is missed if that platform's time.monotonic
          counts suspend (both clocks then advance together)."""
        a = self.a
        aware = SPAN_CLOCK_NAME != "monotonic"
        record = {
            "requested_s": a.observe,
            "interval_s": a.interval,
            "clock": SPAN_CLOCK_NAME,
            "suspend_aware": aware,
            "started_at": None,
            "finished_at": None,
            "iterations": 0,
            "elapsed_s": 0,
            "max_gap_s": None,
            "max_check_s": 0,
            "slow_checks": 0,
            "max_late_s": 0.0,
            "late_tolerance_s": None,
            "breach": None,
            "cadence_warning": None,
            "wall_skew_s": 0,
            "wall_step": None,
            "ok": False,
        }
        self.evidence["observe"] = record
        baseline = self.evidence["post"].get("current_system")
        t0 = SPAN_CLOCK()
        w0 = WALL_CLOCK()
        record["started_at"] = wall_iso(w0)

        def read():
            span, wall = SPAN_CLOCK(), WALL_CLOCK()
            # wall time gained on SPAN_CLOCK since the window started
            return span, (wall - w0) - (span - t0)

        def unseen(skew, before):
            """Suspend only wall time can show (the fallback)."""
            return 0.0 if aware else max(0.0, skew - before)

        def note_late(value, tolerance):
            if value > record["max_late_s"]:
                record["max_late_s"] = ceil3(value)
                record["late_tolerance_s"] = ceil3(tolerance)

        def breach(n, kind, value, tolerance):
            record["breach"] = {
                "check": n,
                "kind": kind,  # late | suspended
                "value_s": ceil3(value),
                "tolerance_s": ceil3(tolerance),
            }

        def check_done(check):
            """Close the timing of a check (also one that raised); returns
            (seconds suspended, span, awake seconds)."""
            t, awake, tolerance, before = check
            awake_s = AWAKE_CLOCK() - awake  # read before the span clock, so a
            t_end, skew = read()  # suspend between the two reads counts
            span = t_end - t
            stalled = span - awake_s + unseen(skew, before)
            record["max_check_s"] = max(record["max_check_s"], round(span))
            if awake_s > a.interval:
                record["slow_checks"] += 1
            note_late(stalled, tolerance)
            return stalled, span, awake_s

        wait = check = None
        n = 0
        prev_start, prev_awake, ready = None, 0.0, t0  # ready: when check n may start
        try:
            while True:
                n = record["iterations"] + 1
                due = max(t0 + min(a.interval * n, a.observe), ready)
                tolerance = max(MIN_LATE_TOLERANCE, min(a.interval, due - ready))
                wait = (due, tolerance, read()[1])
                while True:
                    t, skew = read()
                    if t >= due:
                        break
                    SLEEP(min(due - t, SLEEP_SLICE))
                # That one reading is both the lateness measure and the check
                # start: nothing between them goes unmeasured.
                late = t - due + unseen(skew, wait[2])
                note_late(late, tolerance)
                wait = None
                if prev_start is not None:
                    gap = t - prev_start
                    record["max_gap_s"] = max(record["max_gap_s"] or 0, ceil3(gap))
                    expected = max(a.interval, prev_awake)
                    worst = record["cadence_warning"] or {"gap_s": 0}
                    if gap > expected + a.interval / 2 and gap > worst["gap_s"]:
                        record["cadence_warning"] = {
                            "check": n,
                            "gap_s": ceil3(gap),
                            "expected_s": ceil3(expected),
                        }
                if late > tolerance:
                    breach(n, "late", late, tolerance)
                    self.observe_failed(
                        record,
                        n,
                        None,
                        [
                            f"check would start {ceil3(late):.3f}s after it was due "
                            f"(tolerance {ceil3(tolerance):.3f}s); the host went unsampled, was the runner suspended?"
                        ],
                    )
                check = (t, AWAKE_CLOCK(), tolerance, skew)
                record["last_probes"] = []
                state, problems = self.health("observe", record["last_probes"])
                stalled, span, prev_awake = check_done(check)
                check = None
                record["iterations"] = n
                prev_start, ready = t, t + span
                if state.get("current_system") != baseline:
                    problems.insert(0, "the running system changed during observation")  # fmt: skip
                if stalled > tolerance:
                    breach(n, "suspended", stalled, tolerance)
                    problems.append(
                        f"check spent {ceil3(stalled):.3f}s suspended (tolerance {ceil3(tolerance):.3f}s); "
                        "the host went unsampled, was the runner suspended?"
                    )
                if problems:
                    self.observe_failed(record, n, state, problems)
                if read()[0] - t0 >= a.observe:
                    break
        finally:
            if check:
                stalled, _, _ = check_done(check)
                if stalled > check[2] and record["breach"] is None:
                    breach(n, "suspended", stalled, check[2])
            elif wait:
                due, tolerance, before = wait
                t, skew = read()
                late = t - due + unseen(skew, before)
                note_late(late, tolerance)
                if late > tolerance and record["breach"] is None:
                    breach(n, "late", late, tolerance)
            t, skew = read()
            wall = WALL_CLOCK()
            record["elapsed_s"] = round(max(0.0, t - t0))
            record["wall_skew_s"] = round(skew)
            if abs(skew) > MIN_LATE_TOLERANCE:
                record["wall_step"] = "forward" if skew > 0 else "backward"
            if wall < w0:  # stepped back past the start: never an inverted pair
                wall, record["wall_step"] = w0, "backward"
            record["finished_at"] = wall_iso(wall)
            if aware and record["wall_step"]:
                say(
                    f"WARNING: observe: the wall clock moved {record['wall_skew_s']}s against "
                    f"{SPAN_CLOCK_NAME} during the window; spans are from {SPAN_CLOCK_NAME}"
                )
        record["ok"] = True
        summary = f"{record['iterations']} check(s) over {record['elapsed_s']}s passed (interval {a.interval}s"
        if record["max_gap_s"] is not None:
            summary += f", largest gap {round(record['max_gap_s'])}s"
        if record["slow_checks"]:
            summary += f", {record['slow_checks']} check(s) slower than the interval, longest {record['max_check_s']}s"
        if record["cadence_warning"]:
            summary += (
                f", WARNING cadence gap {round(record['cadence_warning']['gap_s'])}s"
            )
        if not aware:
            summary += ", suspend detection by wall clock only"
        return summary + ")"

    def observe_failed(self, record, n, state, problems):
        if state is not None:
            record["last"] = {
                "system_state": state.get("system_state"),
                "failed_unit_count": state["failed_unit_count"],
                "new_failed_units": self.evidence["failed_units"]["new"],
                "changed_failed_units": self.evidence["failed_units"]["changed"],
            }
        raise StageFailed(f"observation check {n}: " + "; ".join(problems))

    # --- driver ---------------------------------------------------------------
    def run(self):
        plan = [
            ("inputs", self.stage_inputs),
            ("preflight", self.stage_preflight),
            ("pre-state", self.stage_pre_state),
            ("check", self.stage_check),
            ("switch", self.stage_switch if self.a.switch else None),
            ("post", self.stage_post),
            ("observe", self.stage_observe if self.a.observe else None),
        ]
        code, failed = EXIT_PASS, None
        try:
            for name, fn in plan:
                st = self.stages[name]
                if failed:
                    break
                if fn is None:
                    st["status"] = "skipped"
                    continue
                st.update(status="running", started_at=now(), log=str(self.log(name)))
                say(f"stage {name}: running (log {self.log(name)})")
                try:
                    st["summary"] = self.clean(fn())
                    st["status"] = "passed"
                except StageFailed as e:
                    st.update(
                        status=e.outcome,
                        summary=self.clean(e.summary),
                        exit_code=e.exit_code,
                    )
                    failed = name
                    code = EXIT_UNKNOWN if e.outcome == "unknown" else EXIT_FAIL
                except Exception as e:  # noqa: BLE001 - recorded, never swallowed
                    # Anything unexpected still ends in a failed-stage record;
                    # inside the switch the activation's state is unknown.
                    outcome = "unknown" if name == "switch" else "failed"
                    st.update(
                        status=outcome,
                        summary=self.clean(f"internal error: {type(e).__name__}: {e}"),
                        exit_code=None,
                    )
                    failed = name
                    code = EXIT_UNKNOWN if outcome == "unknown" else EXIT_FAIL
                st["finished_at"] = now()
                say(f"stage {name}: {st['status']}: {st.get('summary', '')}")
        except KeyboardInterrupt:
            running = next(
                (s for s in self.stages.values() if s["status"] == "running"), None
            )
            if running:
                running.update(status="interrupted", finished_at=now())
                failed = running["name"]
            else:
                failed = failed or "interrupted"
            code = EXIT_INTERRUPTED
        return self.finish(code, failed)

    def finish(self, code, failed):
        ev = self.evidence
        ev["result"] = {
            EXIT_PASS: "passed",
            EXIT_UNKNOWN: "unknown",
            EXIT_INTERRUPTED: "interrupted",
        }.get(code, "failed")
        ev["failed_stage"] = failed
        if failed in self.stages:
            ev["message"] = self.stages[failed].get("summary")
        path = self.run_dir / "evidence.json"
        st = self.stages["evidence"]
        st.update(status="passed", started_at=now(), finished_at=now(), log=str(path))
        ev["finished_at"] = now()
        ev["stages"] = list(self.stages.values())
        tmp = path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(ev, indent=2, sort_keys=False) + "\n")
        os.replace(tmp, path)
        say(
            f"result: {ev['result']}"
            + (f" at stage {failed}: {ev['message']}" if failed else "")
        )
        units = ev["failed_units"] or {}
        if units.get("tolerated"):
            say(
                f"WARNING: {len(units['tolerated'])} failed unit(s) predate this run and were tolerated: "
                f"{units_text(units['tolerated'])} (fix them, or use --require-clean to fail on them)"
            )
        elif (ev["pre"] or {}).get("failed_units") and not units:
            say(f"WARNING: failed unit(s) before this run: {units_text(ev['pre']['failed_units'])}")  # fmt: skip
        say(f"evidence: {path}")
        print(path)
        return code


def main(argv):
    args = parse_args(argv)
    try:
        admitted = admit(args.host)
        run_dir = make_run_dir(args.run_dir or default_run_dir(args.host))
    except Refused as e:
        say(str(e))
        return EXIT_REFUSED
    say(f"run directory: {run_dir}")
    return Validation(args, admitted, run_dir).run()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
