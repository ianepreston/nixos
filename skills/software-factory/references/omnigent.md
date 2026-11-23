# Omnigent delegation adapter

Use this only when running the supervisor in Omnigent. Discover the current
tool schemas; these names describe capabilities, not a promise that a
particular version has every argument or harness.

Prefer one Polly supervisor running the canonical factory workflow, with
direct implementation and review workers. Polly's generic fanout defaults
are not the factory's limits: a per-turn dispatch cap does not cap concurrent
descendants. Its worktree/registry conventions must not create a second owner
or bypass the shared reservations. Repo worktrees, metadata/PII rules and
authorization remain authoritative.

## Discover and launch

- `sys_session_get_info({})` reports the bound host's `configured_harnesses`.
  A harness is ready only when its value is `true`; missing or unknown values
  need a bounded preflight. `sys_agent_list` identifies registered agents and
  host availability. Do not dispatch a worker marked unavailable.
- `sys_list_models` reports the models available in the calling agent's
  context; a supervisor's own model list does not prove a different worker's
  model is usable. Use worker defaults unless a suitable override is verified.
- Reserve a worker slot before dispatch. For an existing registered agent,
  `sys_session_create(agent_id=…, title=…)` creates an idle child when the
  initial message is omitted. Persist its returned `conversation_id`, then
  drive that child with `sys_session_send(session_id=…, args=…)`. A runtime
  exposing declared named workers may instead support named dispatch; follow
  its advertised schema and still reserve before launch.
- Map the packet's role to an accepted runtime `purpose` when required.
  Polly's purpose guard accepts `implement`, `review`, `explore` and `search`,
  not `validate`. A validator doing read-only probes can use `explore`; one
  performing an explicitly authorized activation needs a bounded `implement`
  packet that permits only that validation action and excludes source edits.
- Use default child placement for parent/child supervision. `same_host` and
  `managed` placements create independent sessions whose replies are not
  forwarded to the parent; do not accidentally select them for this workflow.
  Managed placement also needs a configured provider and approved profile.
- Supply the full task packet with an absolute worktree path and require the
  worker to confirm that cwd. Siblings can share a filesystem; sessions do not
  create Git worktree isolation automatically. Do not assume repo skills were
  inherited: pass the canonical paths and ask the worker to read them.

If using an outer supervisor with Polly as an issue-level child, the child
coordinator itself and every descendant consume worker slots. With two slots,
that leaves one worker below Polly at a time. Require shared claims or choose
a direct coder instead. Generic Polly workers may use approval bypass and
have access to the caller's credentials; a prompt prohibition is not a
technical deployment gate. Do not claim sandboxing or permission enforcement.

## Dispatch arguments

- Call `sys_advise_models` before every dispatch. For a **new** session pass
  its recommended model as `args.model` (IDs carry the `system.ai.` prefix);
  a model recorded unavailable in `plan` metadata is excluded from advice
  and fallbacks alike. Precedence: a verified override, else the advice, else
  the last model known to work for that worker, else a fallback not recorded
  unavailable (`system.ai.gpt-6-2-sol` for `codex`,
  `system.ai.claude-opus-5-5` for `claude_code`), else the worker default.
- A continuation (same title, or `session_id`) runs on the session's
  **original** model and ignores `args.model`; start a new title to change
  model or vendor, and keep the same session when a denied-action follow-up or
  a pending report needs the same child.
- Set `purpose` on every `sys_session_send`, including continuations.

## Collect, interrupt and resume

Omnigent child completion may wake the parent with an inbox notice; collect
with `sys_read_inbox`. `sys_session_get_info(session_id=…)` exposes lifecycle
state and pending approval prompts; `sys_session_get_history(conversation_id=…)`
supplies recent output. Inspect those when a result is empty, unclear or
waiting, and retain the recorded handle so a supervisor restart can reconcile
the child. Do not infer that every harness forwards questions, supports human
takeover, or resumes the parent identically; verify the selected pair in the
first pilot.

An inbox entry marks the end of a child turn, not the outcome of its work.
Summaries can arrive truncated or as a single progress sentence while the full
report sits in the child's history; a child can also yield with a build or
monitor still running, then finish a later turn without another notice.
Inspect the **same recorded child** with both tools when:

- an inbox entry describes pending work, reads as a progress note, or is
  truncated; or
- a resumed supervisor finds a recorded worker whose outcome is unresolved,
  including when its inbox is empty.

Read enough history to see the last complete assistant message. The defaults
(10 items, 2000 characters each) clip long reports; raise `tail_items` (at most
50) and `content_max_chars`. To page one long item, use `tail_items=1` and step
`content_offset_chars` until the ` [truncated]` suffix disappears, but first
confirm that the newest item is the report: it can be a tool result or a later
progress note, in which case read more items instead. Compare that output with the packet's completion criteria and required output, not with
the child's status alone: `idle` without a final report is still unresolved.

- **Outcome in history** (final report, PR head, explicit failure or
  blocker): record it in task `evidence`/`children`. Do not redispatch work
  the history shows was done. An outcome is not proof the child has stopped:
  a build, monitor or validator can still be running after a PR or failure is
  reported. Release the worker claim through the factory's normal
  collect-then-release path only after confirming both that
  `sys_session_get_info` no longer reports the child running and that no
  build, monitor or validator it launched is still active (per its report and
  history). If either is uncertain, keep the claim and treat it as the next
  case.
- **Work may still be active** (running build, monitor, validator or pending
  approval): record the child session ID, the outstanding work, where its
  result will appear and the resume condition. Keep the worker claim; the
  next completion notification or supervisor resume re-runs this check.
- **Still unclear:** treat it as possibly active and keep the claim. Continue
  the same child to ask for its final report rather than starting a new one.

This uses the existing resume path and completion notifications. Do not add a
polling loop, timer or scheduled task to watch the child.

Example: the inbox entry reads "Started `task check`; monitor running, will
report when it exits." History shows the check still running and no PR. Record
`children[implement-123]: {session: conv_…, state: running, pending: "task
check monitor", result_at: "child history final message", resume: "next
completion notice or resume; re-read history"}`, keep `worker:implement-123`,
and continue independent work. When a later notice or resume shows the
complete report with head SHA and PR URL, record it. Release
`worker:implement-123` only once the child is no longer running and its report
and history show the monitor exited with nothing else it launched still
active; otherwise keep the claim and record what remains.

The packet's required output (see the factory skill) asks workers to end the
dispatched turn with the complete report and, if background work is pending,
to say what is still running and where its result can be read. A progress
note without that is the cue to run the check above.

Forward a genuine question to the human with the issue and resume condition.
Do not answer a child's protected-action approval on the user's behalf.
Where human takeover is available, ask the user to open the named child;
record the resulting decision/evidence back in the supervisor state.

Continue the same child by its session ID, reserving a worker slot again if
the earlier turn had stopped and released it. Use `sys_cancel_task` only with
the cancellation identifier documented/returned by that runtime. A request
to cancel is not proof of termination: some harnesses are best-effort. Keep
its reservation until runtime evidence confirms it has stopped. A boot
failure removes that worker from this run's roster rather than triggering
repeated dispatch to the same unavailable harness.

**After a denied commit, push or PR.** The child's final report names the
denied command and leaves its edits in the worktree. To have it finish or fix
something, continue the same child with `sys_session_send(session_id=…,
args=…)` (with `purpose`, e.g. `implement`),
under its worker claim: reuse the claim if the child still holds one (a
claim cannot be taken twice, and a second token would use a second slot), and
reserve a new token only if the earlier claim was released. Do not ask it to
retry the denied action, and do not ask it to add an attribution footer.
If the remaining step is only commit/push/PR, the supervisor runs
`skills/software-factory/scripts/finish_child.py` from its own shell, as the
factory skill describes (no attribution footer, whatever the child's
harness mandates). A supervisor without a shell reports the outstanding
steps and the exact script command for the human instead.

**Budget errors.** A model whose budget is exhausted fails the dispatch (or
the child's first turn) with a 403 whose body carries `BUDGET_EXCEEDED`, e.g.
`{"error_code": "BUDGET_EXCEEDED", …}`; permission errors look similar with a
different code. `sys_advise_models` does not know about the budget and may
keep recommending that model. Read it from the `sys_session_send` result or
`sys_session_get_history`, record the model unavailable for the run, and
redispatch on a model that worked earlier. This is a task failure, not a boot
failure.

Completion wakes cover children, not arbitrary external events. If only a
human answer, hardware change or upstream release can unblock work, leave a
durable waiting state and an explicit resume instruction. This workflow does
not install timers, recurring tasks, change model providers or grant access.
