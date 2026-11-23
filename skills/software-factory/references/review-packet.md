# Review packet template

Use for every `review` dispatch so cycles converge. Give the reviewer a saved
diff file (absolute path), base and head SHAs and the acceptance contract; not
the implementer's conclusions. Review is read-only.

Include in the packet:

- **Verdict format.** Report blocking issues only, plus short non-blocking
  notes. End the turn with the complete report and an explicit verdict
  (`APPROVE` or `REQUEST_CHANGES`); a progress note is not a report.
- **All findings of a class in one pass.** When a defect is one instance of a
  class (for example, every sink that copies a value into evidence or a log),
  enumerate the whole class now rather than the first instance found.
- **Plausibility ceiling.** For scripts that handle credentials, evidence or
  redaction, flag only failure modes plausible in normal operator use, not
  adversarial constructions.
- **Scope.** Judge the diff against the acceptance contract; do not widen it.

For implementers of evidence, logging or credential-handling work, the packet
asks for a short list of sinks and trust boundaries in the final report, so the
first review can check them.

When the correction cap is reached on a security-adjacent change, the
supervisor surfaces the open class of findings to the user, not only the
latest item. The two-cycle default and the review bar are unchanged.
