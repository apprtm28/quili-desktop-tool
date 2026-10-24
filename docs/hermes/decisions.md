# Quili × Hermes — Decision Log

Personal macOS fork of Quili that absorbs [`slack-to-hermes-tool`](../../../slack-to-hermes-tool) (decisions D1–D19 there).
Agreed in a grilling session on 2026-10-23. Q-numbers are this log's; slack-to-hermes decisions are cited as `S2H-Dn`.

## Q1 — Personal fork, macOS only
**Status:** Agreed

- Everything here is macOS-only. Windows keeps today's paraphrase / translate / summarize-thread behaviour and is not
  built or changed.
- `AGENTS.md` lists the Hermes features under *Intentional platform differences*, so the parity rule is scoped
  rather than silently broken.

## Q2 — One app: Quili absorbs slack-to-hermes
**Status:** Agreed

- Quili's UI and interaction model are kept. Slack-to-hermes is retired once Quili covers it; its repo stays as history.
- Ported (adapted to Quili's style): SSH CLI transport, stream-json parser, error classifier, encrypted store,
  range collector / message merger, DOM-class message reading.
- Reason: two apps driving the same Slack accessibility tree fight over scrolling, need two Accessibility grants,
  and put two buttons on Slack.

## Q3 — Routing: fast path vs Hermes
**Status:** Agreed

| Feature | Path |
|---|---|
| Paraphrase, Translate | Direct, fast: `opencode run` on the Mac (Q13) |
| Summarize thread, Summarize range | Hermes `work` profile (S2H-D6: company Slack data only via `work`) |
| Ask Hermes (follow-ups) | Hermes `work`, same session |
| Draft note for Obsidian | Hermes `work`, same session |

Both paths bill the same `opencode-go` account; Hermes adds its context, memory and vault.

## Q4 — Main-channel selection: hover chips
**Status:** Agreed

- Hovering a message in Slack's main channel shows a small green Quili chip at the message's right edge.
- First click marks **Start**, second click marks **End**; Quili then collects the range (scrolling Slack's
  virtualised list, `RangeCollector`) and shows it in a Quili bubble where messages can be unticked.
- From that bubble: **Summarize** or **Ask Hermes…**. Quili's visual language throughout (green round/pill controls,
  white rounded cards, system font 13).

## Q5 / Q9 — Obsidian write-back: Hermes drafts, Quili writes over SSH
**Status:** Agreed (Q9 refines Q5)

- **Save to work context** asks Hermes (same session) for a note draft in a fixed `<quili_note>` block. No tool use.
- A Quili bubble shows the draft as editable text with its target path; **Approve** or **Discard**.
- On Approve Quili runs one fixed command over SSH, note on stdin, that creates
  `~/ObsidianVault/03-resources/quili-work-context/<yyyy-mm-dd>-<slug>.md` on `apprtm`. The file name is validated
  on the Mac (`[a-z0-9-]`), the remote side refuses to overwrite (`noclobber`), and no other path can be written.
- The file lands in the vault Hermes reads (LiveSync distributes it), so later sessions can use it.

## Q6 — Asking Hermes: input row inside the bubble
**Status:** Agreed

- The summary / range bubble gains an **Ask Hermes…** row. The bubble stays non-activating; it only becomes key when
  the row is clicked. Return sends, Esc hands focus back to Slack.
- Questions and answers stack in the same bubble below the summary; it scrolls.
- The reply streams into the bubble (verified 2026-10-23: Hermes does stream text on `deepseek-v4.1-flash`), with an
  elapsed-time status in the header.

## Q7 — One Hermes session per Slack source
**Status:** Agreed

- A thread or a collected range is one source → one Hermes session titled `quili: <channel> – <first words>`.
- Clicking ✦ on a thread discussed before reopens its transcript; **Refresh** sends only new messages (S2H-D9).
- No topic menu or multi-source baskets: Hermes' `session_search` recalls other sessions on its own.
- Sessions and transcripts are kept in an AES-GCM encrypted file (key in Keychain), purged after 30 unused days.

## Q8 — Coverage: warn, never block; Save requires a clean read
**Status:** Agreed

- Quili's `ThreadReader` stays the base reader. It now reports what it knows: oldest messages dropped for length,
  scroll stopped by the step/time budget, start not reached, and replies read vs Slack's reply count when readable.
- The bubble header shows one coverage line when something is off, with **Retry read**. Nothing changes when clean.
- **Save to work context** is blocked on an unclean read unless "Save anyway" is chosen.

## Q10 — Hermes toolset and write guard
**Status:** Agreed; verified 2026-10-23

- Turns run with `-t file,skills,session_search,clarify,todo`.
- Verified live: with `-t`, `tool_search` no longer reaches MCP tools (Jira `createJiraIssue`/`editJiraIssue`
  unreachable), resolving S2H-D18's open question. Remaining tools: `read_file`, `search_files`, `write_file`,
  `patch`, `skill_view`, `skills_list`, `session_search`, `todo_list`, `clarify`, `tool_search/describe/call`.
- `file` bundles read and write (no read-only toolset exists). The preamble forbids writes; Quili scans each reply
  for signs of a write (`write_file`, `patch`) and shows a visible warning in the bubble.

## Q11 — Transport: Hermes CLI over SSH now, measure before `hermes serve`
**Status:** Agreed

- One `ssh … hermes -p work chat --query-file - --format stream-json` process per turn, with SSH connection reuse
  (`ControlMaster auto`, `ControlPersist 10m`) and the restricted toolset.
- Measured 2026-10-23: one-shot restricted turn ≈ 11 s end to end. Revisit `hermes serve` if summaries stay > 12 s.

## Q12 — Hermes unreachable: explicit per-use fallback
**Status:** Agreed

- The bubble shows *Can't reach Hermes* with the reason and **Retry** / **Summarize directly this once**.
- The direct summary uses the fast path, is labelled *Not saved to Hermes*, and offers no Ask or Save. Never automatic.

## Q15 — History, adding context later, and updating saved notes
**Status:** Agreed 2026-10-24

- Menu bar → **Recent Hermes conversations** lists the stored conversations (newest first, kind, time, whether a note
  was saved). Choosing one reopens it in the bubble under the menu-bar icon: transcript, Ask Hermes, saving.
- The Ask box is multi-line: Return sends, ⌘↩ (or ⇧↩) adds a line, so longer context can be pasted in later.
- Once a note was saved, **Update saved note** asks Hermes for only what is new since (it may read the note) and, after
  approval, Quili **appends** it to that same file (it must exist inside the notes folder). Never overwrites.
  **Save as new note** still writes a separate note.

## Q14 — Ask Hermes about a selection in any app (⌃⌥H)
**Status:** Agreed 2026-10-23

- ⌃⌥H (or the menu-bar item *Ask Hermes about selection*) sends the text selected in the frontmost app — an email in
  Gmail, a page in Chrome — to the Hermes `work` profile, in the same conversation bubble near the pointer.
- The selection is read through Accessibility when the app reports it, otherwise with Cmd+C (the clipboard is restored).
- One selection = one source = one session (no merging of selections; that is Q7's deferred basket). Ask Hermes and
  Save to work context work as for Slack. Everything selected goes to `work`, by the user's explicit choice.
- Revised 2026-10-24: the selection is not sent at once. It lands in the Ask box, focused, to edit and add a question;
  Return sends it as the user's own message (the prompt warns that copied parts may carry other people's
  instructions). The same text selected again continues its earlier conversation.
- The bubble can be moved (drag the header) and resized (corner grip); both are remembered, double-click the header to
  go back to automatic. Once shown it stays where it is while Hermes writes.

## Q13 — The fast path lives inside Quili
**Status:** Agreed

- Quili spawns `opencode run --format json` itself (prompts in Swift). Settings gain an **AI engine** choice:
  *Server URL* (original), *opencode (local)*; the mock toggle stays. Default model `opencode-go/deepseek-v4.1-flash`.
- `tools/agent_server.py` stays as a development tool; nothing depends on it.
