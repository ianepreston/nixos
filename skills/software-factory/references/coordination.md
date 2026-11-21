# Local coordination contract

The standard-library helper `../scripts/factory.py` records tasks and makes
resource claims transactionally with SQLite on macOS/Linux. It performs no
GitHub, agent dispatch or deployment action. It is coordination for a trusted
supervisor and cooperating children, not access control. Other clones,
unrelated sessions, CI and host timers do not honor these claims automatically.

Run from any worktree of this checkout (or pass `--repo /absolute/worktree`).
State is `<git-common-dir>/software-factory/state.sqlite3`, never tracked.
The helper versions its schema and refuses an incompatible database without
changing it; preserve that state and reconcile using its originating helper.
Use the absolute helper path in child packets. Python 3 and Git are required.

```sh
factory_cli=/absolute/worktree/skills/software-factory/scripts/factory.py
factory_owner='<unique-supervisor-session-id>'
python3 "$factory_cli" show
python3 "$factory_cli" --owner "$factory_owner" init --max-active 1 --max-workers 2
python3 "$factory_cli" --owner "$factory_owner" plan --data-file /tmp/factory-plan.json
python3 "$factory_cli" --owner "$factory_owner" task 123 --status ready --data-file /tmp/issue-123.json
python3 "$factory_cli" --owner "$factory_owner" claim issue:123
python3 "$factory_cli" --owner "$factory_owner" claim worker:implement-123 --issue 123
```

`init` is idempotent for the same owner and limits, and refuses a different
owner. The initial version supports one or two active issues and one or two
children; validation and expensive builds each have one slot. A worker/build/
validation claim requires an existing issue claim. Resource names are exactly
`issue:<number>`, `worker:<token>`, `build`, and `validation`. Tokens use letters,
digits, dots, underscores or hyphens. Different tokens count as different
children; use a fresh token per dispatch attempt and keep the runtime handle.

`plan --data-file` shallow-merges a JSON object into supervisor metadata. Save
the ordered finite issue batch, prioritization rationale (including enabling
work), overall action boundaries and pending batch-level decisions there.
This remains intact across takeover; task sort order is not queue priority.

`task` sets status and shallow-merges a JSON object from `--data-file` into the
task's metadata; it does not verify the truth of a status or enforce the phase
sequence. Save nested values in full when updating them. Store the acceptance
packet before dispatch; then update it with the returned runtime handle and
result. Suggested metadata fields:

| Field | Contents |
| --- | --- |
| `packet` | Scope, accepted decisions, dependencies, worktree, branch, base SHA, acceptance criteria, permitted actions |
| `children` | Dispatch token, purpose, harness, session/task/cancellation handles, running/terminal state |
| `evidence` | Head SHA, effective inputs, command/results, review revision, live closure/generation, manual observations |
| `waiting` | Previous phase, question/action, recommendation, exact resume condition |
| `decisions` | User answer, scope, applicable host/action/step and revision when relevant |
| `pr` | URL, head SHA, readiness and observed merge/rollout state |

Do not store credentials, decrypted inputs or raw private logs. Summarize
evidence; keep any sensitive supporting files local and out of PR bodies.
`show` includes the last 20 mutation events to help reconstruct interrupted
handoffs. Those events are history, not proof that an external action ran.

```sh
python3 "$factory_cli" --owner "$factory_owner" claim build --issue 123
# Run the agreed build/check, record its outcome, confirm the command stopped.
python3 "$factory_cli" --owner "$factory_owner" release build
# Collect a terminal result before releasing the child slot.
python3 "$factory_cli" --owner "$factory_owner" release worker:implement-123
python3 "$factory_cli" --owner "$factory_owner" task 123 --status reviewing --data-file /tmp/issue-123-review.json
```

Claims do not expire and are not reentrant: claiming an occupied resource
fails even for the same issue/owner. After an uncertain result inspect `show`
and runtime state; never treat an existing claim as a new dispatch grant.
Issue release fails while any dependent claim remains. Release `validation`
only after the required checks/observation, or
after the operator has resolved an interrupted/failed activation and confirmed
the host is safe to reuse. Reserve both `build` and `validation` if validation
also builds a closure.

On a new supervisor session, inspect the previous owner's runtime before
taking over. Stop if it might still be dispatching. After it has stopped:

```sh
python3 "$factory_cli" --owner '<new-session-id>' takeover --previous-owner '<recorded-old-session-id>'
```

Takeover compares the old owner and preserves every task and claim. Reconcile
children and host state before releasing anything or starting new work; a
crashed supervisor does not imply its children or activation have stopped.
Mutating commands reject a stale owner after takeover. Do not delete the
database or clear claims to bypass uncertainty. To change concurrency after
an explicit user request, use `limits --max-active 2 --max-workers 2`; lowering
below current claims is refused.

These reservations cannot close the crash window between persisting a dispatch
intent and receiving its handle. Record the token in the child's title/input,
look for that task in runtime history, and treat ambiguity as occupied capacity
until reconciled. Similarly, no local record can prove host identity or replace
the activation checks in root guidance.
