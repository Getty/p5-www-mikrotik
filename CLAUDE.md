# CLAUDE.md — WWW::MikroTik

Simple Perl client for the RouterOS REST API (`https://<router>/rest`). One Moo class,
`LWP::UserAgent`, HTTP Basic auth; the RouterOS console path is the API surface.
Deliberately **less** than `../p5-www-hetzner` (the style reference): no entity classes,
no IO role, no CLI. The design, phase plan and API digest are in `TODO.md`; once code
exists, the code is the truth and `TODO.md` is history.

Build and test: `dzil build`, `dzil test`, `dzil clean`. While iterating: `prove -lr t/`
(`-r` — plain `prove -l t/` is not recursive). The suite is mock-driven and needs no
router. Never `dzil release` without explicit permission.

## Delegation

Delegate behavior-relevant code to the right agent instead of touching it yourself —
the principle, the lanes and this repo's hazards are in `.claude/rules/www-mikrotik-rules.md`.

| Task | Agent |
|---|---|
| Implement / refactor / debug anything under `lib/` | `www-mikrotik-worker` (default) |
| Write or extend tests in `t/` | `www-mikrotik-test-writer` |
| POD in the house format | `www-mikrotik-doc-writer` |
| Pre-release audit | `www-mikrotik-release-checker` |

The agents carry their conventions via `briefing.skills` (see `.claude/agents/`); the
main agent delegates rather than loading them. Skill sources live in `.claude/skills/` —
`perl-www-mikrotik` is this repo's own (the REST API and the module's intended shape),
the rest are hardlinks from the shared library (edit them only via `manage-skills`, never
with Edit/Write). Work is tracked on the local `karr` board.
