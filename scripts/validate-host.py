#!/usr/bin/env python3
"""Live-validation driver for a dev host (#1063).

    validate-host.py --host H [--switch] [--probe CMD]... [--observe DUR]
                     [--interval DUR] [--local-secrets]
                     [--override-input NAME VALUE]... [--run-dir DIR]

Runs one validation sequence and writes a log per stage plus one JSON evidence
record (no secret contents) into a run directory outside the git checkout:

  admit      refuse unless hostSpecs say `serverEnvironment = "dev"` for H
             (fails closed: unknown host, null, prod or an eval error all
             refuse); nothing is written and nothing connects before this
  inputs     source SHA and dirty count, the locked nix-secrets rev, the
             effective input overrides, and the expected closure from the
             helper's own `--dry-run` evaluation (no connection)
  preflight  scripts/activate-nixos.sh --preflight; on failure the helper's
             classified message is the result
  pre-state  read-only: running closure, generation, booted closure, system
             state, failed units, next nixos-upgrade timer; refuses to go on
             while nixos-upgrade.service is running
  check      the helper's --action check (build + identity, activates nothing)
  switch     only with --switch: the helper's --action switch, which repeats
             its preflight and identity assertions; any error stops the run
  post       running closure/generation (with --switch it must be the expected
             closure), `systemctl is-system-running` = running, no failed
             units, every --probe exits 0 (probes run on the target)
  observe    only with --observe: repeat the post checks every --interval;
             the running closure must not change
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


def run_capture(argv, timeout, stdin_text=None, log=None):
    """Run a bounded, non-activating command. Returns (rc, stdout); rc is None
    on timeout. stderr (and, when given, stdout) is appended to `log`."""
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
            sink.write(out)
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


def describe_input(name, value):
    """An input override for the evidence: its location without query,
    fragment, userinfo or (for unrecognised URLs) path; safe `rev`/`ref`
    values as separate fields; and a short sha256 fingerprint of the full
    value, so different pins stay distinguishable without being recorded."""
    value = str(value)
    base = value.partition("?")[0].partition("#")[0]
    query = value.partition("?")[2].partition("#")[0]
    rec = {"name": name, "fingerprint": hashlib.sha256(value.encode()).hexdigest()[:12]}
    if base.startswith(SAFE_REF_PREFIXES) or "://" not in base:
        rec["value"] = scrub(base)
    else:
        parts = urllib.parse.urlsplit(base)
        origin = parts.hostname or ""
        try:
            port = parts.port
        except ValueError:
            port = None
        rec["value"] = f"{parts.scheme}://{origin}" + (f":{port}" if port else "")
    params = urllib.parse.parse_qs(query, keep_blank_values=False)
    rev = (params.get("rev") or [None])[-1]
    if rev and SAFE_REV_RE.fullmatch(rev):
        rec["rev"] = rev
    ref = (params.get("ref") or [None])[-1]
    if ref and SAFE_REF_RE.fullmatch(ref) and not TOKEN_RE.search(ref):
        rec["ref"] = ref
    return rec


def admit(host):
    """Fail closed unless the flake's hostSpec says this is a dev server."""
    if not HOST_RE.fullmatch(host):
        raise Refused(f"invalid host name {host!r}")
    attr = f"{REPO}#nixosConfigurations.{host}._module.specialArgs.hostSpec.serverEnvironment"
    try:
        rc, out = run_capture(["nix", "eval", "--json", attr], ADMIT_TIMEOUT)
    except StageFailed as e:
        raise Refused(f"refusing {host}: {e.summary}") from None
    if rc != 0:
        raise Refused(
            f"refusing {host}: no nixosConfigurations.{host} hostSpec could be evaluated (unknown host?)"
        )
    try:
        env = json.loads(out)
    except ValueError:
        raise Refused(f"refusing {host}: unreadable serverEnvironment") from None
    if env != "dev":
        raise Refused(
            f'refusing {host}: serverEnvironment is {json.dumps(env)}, only "dev" hosts may be validated'
        )
    return env


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
    def __init__(self, args, env, run_dir):
        self.a = args
        self.host = args.host
        self.target = f"{USER}@{args.host}"
        self.run_dir = run_dir
        self.input_flags = ["--local-secrets"] if args.local_secrets else []
        for name, value in args.override_input:
            self.input_flags += ["--override-input", name, value]
        self.closure_re = re.compile(CLOSURE_RE % re.escape(self.host))
        self.stages = {
            name: {"name": name, "status": "not-run", "log": None} for name in STAGES
        }
        self.evidence = {
            "schema": "nixos-validate-host/1",
            "host": self.host,
            "target": self.target,
            "server_environment": env,
            "switch_requested": args.switch,
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
            "probes": [],
            "observe": None,
            "stages": [],
        }

    # --- plumbing -------------------------------------------------------------
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

    def remote(self, stage, command, timeout):
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
        rc, out = run_capture(argv, timeout, stdin_text=script, log=self.log(stage))
        lines = out.splitlines()
        if rc is None:
            raise StageFailed(f"read from {self.target} timed out after {timeout}s")
        if "VALIDATE-WRONG-HOST" in lines:
            raise StageFailed(
                f"{self.target} did not report hostname {self.host}; stopping (inspect the ssh route)",
                rc,
            )
        failed = [x.split()[1] for x in lines if x.startswith("VALIDATE-READ-FAILED ")]
        if failed:
            raise StageFailed(
                f"required read '{failed[0]}' failed on {self.host}; stopping", rc
            )
        # A marker alone is not enough: ssh itself must succeed too.
        if rc != 0:
            raise StageFailed(
                f"ssh to {self.target} failed (exit {rc}); stopping, no further connections",
                rc,
            )
        return rc, lines, nonce

    def read_state(self, stage):
        rc, lines, nonce = self.remote(stage, lambda _n: "state", READ_TIMEOUT)
        if f"VALIDATE-END {nonce}" not in lines:
            raise StageFailed(
                f"state read from {self.target} did not complete (exit {rc})", rc
            )
        state = {"failed_units": []}
        for line in lines:
            key, sep, value = line.partition("=")
            if not sep:
                continue
            if key == "failed_unit":
                state["failed_units"].append(value)
            elif key in (
                "hostname",
                "current_system",
                "booted_system",
                "system_profile",
                "system_state",
                "upgrade_service",
                "upgrade_timer_next",
            ):
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
        state["failed_unit_count"] = len(state["failed_units"])
        state["read_at"] = now()
        return state

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
        if state["system_state"] != "running":
            problems.append(f"system state is {state['system_state']!r}, not 'running'")
        if state["failed_unit_count"]:
            problems.append(
                f"{state['failed_unit_count']} failed unit(s): {', '.join(state['failed_units'][:10])}"
            )
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
                last_message(log, ("activate-nixos:",))
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
            msg = last_message(log, ("preflight:", "activate-nixos:"))
            raise StageFailed(
                msg
                or (
                    "preflight timed out"
                    if rc is None
                    else f"preflight failed (exit {rc})"
                ),
                rc,
            )
        return last_message(log, ("preflight: passed",)) or "passed"

    def stage_pre_state(self):
        state = self.read_state("pre-state")
        self.evidence["pre"] = state
        if state.get("upgrade_service") in ("active", "activating", "reloading"):
            raise StageFailed(
                f"nixos-upgrade.service is {state['upgrade_service']} on {self.host}; host state is changing, not validating"
            )
        return f"generation {state['generation']}, {state.get('system_state')}, {state['failed_unit_count']} failed"

    def stage_check(self):
        log = self.log("check")
        rc, _ = run_logged(self.helper("--action", "check"), log, self.a.build_timeout)
        if rc != 0:
            msg = last_message(log, ("preflight:", "activate-nixos:", "activate:"))
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
            msg = last_message(log, ("preflight:", "activate-nixos:", "activate:"))
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
        return (
            f"generation {state['generation']}, running, {len(probes)} probe(s) passed"
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
        a = self.a
        record = {
            "requested_s": a.observe,
            "interval_s": a.interval,
            "iterations": 0,
            "elapsed_s": 0,
            "ok": False,
        }
        self.evidence["observe"] = record
        baseline = self.evidence["post"].get("current_system")
        start = time.monotonic()
        end = start + a.observe
        while True:
            time.sleep(
                max(
                    0.0,
                    min(start + a.interval * (record["iterations"] + 1), end)
                    - time.monotonic(),
                )
            )
            record["last_probes"] = []
            state, problems = self.health("observe", record["last_probes"])
            record["iterations"] += 1
            record["elapsed_s"] = round(time.monotonic() - start)
            if state.get("current_system") != baseline:
                problems.insert(0, "the running system changed during observation")
            if problems:
                record["last"] = {
                    "system_state": state.get("system_state"),
                    "failed_unit_count": state["failed_unit_count"],
                }
                raise StageFailed(
                    f"observation check {record['iterations']}: " + "; ".join(problems)
                )
            if time.monotonic() >= end:
                break
        record["ok"] = True
        return f"{record['iterations']} check(s) over {record['elapsed_s']}s passed"

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
                    st["summary"] = scrub(fn())
                    st["status"] = "passed"
                except StageFailed as e:
                    st.update(
                        status=e.outcome,
                        summary=scrub(e.summary),
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
                        summary=scrub(f"internal error: {type(e).__name__}: {e}"),
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
        say(f"evidence: {path}")
        print(path)
        return code


def main(argv):
    args = parse_args(argv)
    try:
        env = admit(args.host)
        run_dir = make_run_dir(args.run_dir or default_run_dir(args.host))
    except Refused as e:
        say(str(e))
        return EXIT_REFUSED
    say(f"run directory: {run_dir}")
    return Validation(args, env, run_dir).run()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
