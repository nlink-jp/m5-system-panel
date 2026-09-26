# CLAUDE.md — m5-system-panel

**Organization rules (mandatory): https://github.com/nlink-jp/.github/blob/main/CONVENTIONS.md**

Project summary, structure, non-negotiable rules and the known gotchas live in
[AGENTS.md](AGENTS.md). Read it before changing anything here. Scope and the
decisions already made — including the alternatives that were rejected — are in
the [RFP](docs/ja/m5-system-panel-rfp.ja.md); do not reopen them without a reason
the RFP did not consider.

This project restarts the withdrawn m5-notify-deck. Organization ADR-023 was
written from that failure and binds this repository: design from the
documentation, observe on the real system what the documentation does not say,
and announce and undo every change to a machine's state. The rules worth
repeating: the panel accepts nothing that does not verify under the key shared
at setup, and it takes on no role the OS manages.
