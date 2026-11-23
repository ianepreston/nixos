# Review packet template

Use for every `review` dispatch so cycles converge, alongside the inputs
required by **Review and validate** in `SKILL.md`.

Include in the packet:

- **Verdict format.** Report blocking issues only, plus short non-blocking
  notes. End the turn with the complete report and an explicit verdict
  (`APPROVE` or `REQUEST_CHANGES`); a progress note is not a report.
- **All findings of a class in one pass.** When a defect is one instance of a
  class (for example, every sink that copies a value into evidence or a log),
  enumerate the whole class now rather than the first instance found.
- **Plausibility ceiling.** For security-sensitive scripts (credentials,
  evidence, redaction, anything parsing untrusted input), flag failure modes
  plausible at the documented trust boundary, including attacker-controlled
  input the tool is meant to process; skip contrived constructions that
  require a capability the boundary already grants.
- **Scope.** Judge the diff against the acceptance contract; do not widen it.

The review bar and the two-cycle default are unchanged. Implementer sink
lists and cap escalation are in `SKILL.md`.
