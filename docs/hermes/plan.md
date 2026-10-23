# Quili × Hermes — Plan and Status

Decisions: [`decisions.md`](decisions.md). macOS only. Status as of 2026-10-23.

## Phases

| Phase | Goal | Contents | Status |
|---|---|---|---|
| **P1** Fast path in Quili | No Python server needed | `OpencodeClient` (spawns `opencode run`), engine setting, prompts in Swift | ✅ verified (harness: 3.4 s) |
| **P2** Hermes transport | Talk to `work` over SSH | `HermesClient` (stream-json incl. `tool_use`), error mapping, ControlMaster; `HermesSessions` (AES-GCM, TTL) | ✅ verified (harness) |
| **P3** Thread summary via Hermes | ✦ → Hermes session | `ConversationWindow` bubble (summary, coverage line, Ask row, actions), resume + Refresh, fallback (Q12) | ✅ code; live UI test pending |
| **P4** Coverage signals | Honest read reports | `ThreadReader` reports dropped / budget / start reached / replies vs count | ✅ code; live test pending |
| **P5** Save to work context | Hermes drafts, Quili writes | `<quili_note>` draft, editable approve bubble, SSH write with noclobber, clean-read gate | ✅ verified (harness: draft, write, noclobber, bad name) |
| **P6** Main-channel range | Hover chips → range bubble | `ChannelWatcher`, `ChipWindow`, `SlackMessages` (DOM classes), `RangeCollector`, pick list | ✅ code; live test pending |
| **P7** Docs | README / AGENTS.md | Intentional differences, setup, build | ✅ |

## Measured (2026-10-23, harness against `apprtm`)

| Step | Time |
|---|---|
| opencode paraphrase | 3.4 s |
| Hermes summary, new session, cold SSH | 13.1 s (streams: 97 live updates) |
| Hermes follow-up, SSH connection reused | 5.0 s |
| Hermes note draft | 8.4 s |

Text does stream from Hermes on `deepseek-v4.1-flash` (slack-to-hermes' note about one chunk no longer holds).
Q11's 12 s threshold: a new summary is just above it, follow-ups well under. Revisit `hermes serve` only if live use feels slow.

Deferred: expanding a picked message's thread replies ("include replies"); multi-source baskets (Q7).

## Needs a human

- Grant Accessibility again after each rebuild (ad-hoc signature).
- Live-test P6 on a busy channel: chip placement next to Slack's hover toolbar, range collection, restore position.
- Measure real summary latency through Hermes (Q11) and decide on `hermes serve`.
- Remove the old probe line from `~/.hermes/profiles/work/memories/MEMORY.md` (S2H-WP17) if still there.
- Retire the slack-to-hermes app once P6 is confirmed.

## Build on this Mac

The Command Line Tools here can't link SwiftPM manifests or build universal binaries, and a stale
`module.modulemap` breaks every framework import. `mac/build-swiftc.sh` compiles with `swiftc` directly
(arm64) behind a VFS overlay that hides the stale file, then bundles and signs `dist/mac/Quili.app`.
