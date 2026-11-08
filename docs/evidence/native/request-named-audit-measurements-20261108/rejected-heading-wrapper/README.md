# Rejected heading accessibility wrapper

Candidate r2 added a full-width frame, explicit accessibility element with ignored children, and localized heading label to the existing native Label. Both original measurement cases failed before measuring the heading: the accessibility query now finds two same-labelled static-text nodes. The retained trees also show the same narrow AX5 heading frame (x51.3,width307.7,height187.3). This candidate does not establish a correction and was not installed in canonical app code.

Native65/strict1, two executed cases. Original source/result preservation verified; inspection and scoped exports are complete. The included verification scope phrase “unchanged production” means unchanged throughout this candidate run; it must not be read as equality to canonical production. The candidate patch shows the actual difference.

Next: use a native text heading whose accessibility bounds enclose its complete multiline content, while preserving wording, Dynamic Type and header semantics. Keep the failing bounds assertion and capture the full screen plus element crop. Reuse an incremental build path for the next focused check. No audit finding is waived.
