# WWW::MikroTik House Rules

Apply to every task in this distribution unless explicitly overridden. Bias: caution over
speed on non-trivial work. Subagents get their conventions from the skills force-loaded via
`briefing.skills` — this file is for the orchestrating agent.

## Engineering discipline

1. **Think before coding** — State assumptions; ask rather than guess. Push back when a
   simpler approach exists. Stop when confused; name what's unclear.
2. **Simplicity first, surgically applied** — This distribution is *deliberately* one
   class. Minimum code that solves the problem, nothing speculative; no entity classes, no
   IO role, no CLI unless the maintainer asks. Touch only what you must.
3. **Goal-driven execution** — Define success criteria, loop until verified.
4. **Surface conflicts, don't average them** — Contradicting patterns: pick one, explain
   why, flag the other. Don't blend.
5. **Read before you write** — `lib/WWW/MikroTik.pm` is the whole client; read `request`
   before adding a verb. `TODO.md` is the design until the code exists, then the code wins.
6. **Tests verify intent, not just behavior** — Assert the wire: method, URL, headers,
   body bytes, not only the decoded return. Reproduce a bug before fixing it; leave the
   regression test behind.
7. **A red test is a claim before it is a failure** — Before changing code to turn a test
   green, say what the test asserts and whether your fix keeps that claim or replaces it.
8. **Checkpoint and fail loud** — Summarize done / verified / left after each significant
   step. "Done" is wrong if anything was skipped silently; "tests pass" is wrong if any
   were skipped — say so.
9. **Match the codebase's conventions, even if you disagree** — Conformance > taste.

## Delegation

Depends on whether the Agent/Task tool is available to you.

- **You can spawn subagents** (orchestrating main agent): Do NOT touch behavior-relevant
  code yourself — delegate. Your lane: coordinate, inspect, plan, review diffs, run tests,
  manage git, edit `Changes`/`README`/`TODO.md`. When in doubt, delegate. Why: only the
  `www-mikrotik-*` agents get their skills force-loaded via `briefing.skills`; you get no
  briefing and would write Perl without the house rules.

  | Task | Agent |
  |---|---|
  | Implement / refactor / debug anything under `lib/` | `www-mikrotik-worker` (default) |
  | Write or extend tests in `t/` | `www-mikrotik-test-writer` |
  | POD in the house format | `www-mikrotik-doc-writer` |
  | Pre-release audit | `www-mikrotik-release-checker` |

- **You cannot spawn subagents** (you ARE a `www-mikrotik-*` agent): the lock does not
  apply — implement, refactor, debug and test per these rules.

Behavior-relevant = everything under `lib/` and `t/`, request building, auth, JSON
handling, error handling. Prose in `README.md`, `TODO.md` and `Changes` bullets are not.

## Coordination — karr board (always in scope)

Ticket coordination is the orchestrating agent's job, so `karr` is always in scope — don't
invoke the skill first, just use it. Git-native kanban; state lives in `refs/karr/*`.

- `karr list --compact` / `karr board` — open work · `karr show ID` — detail
- `karr create "Title" --priority high --tags a,b --body '…'` · `karr edit ID -a "note"`
  · `karr move ID in-progress --claim NAME` · `karr handoff ID --claim NAME --note "…"`
  — full surface: skill `kanban-issues-karr-cli`

Record drift and follow-up work as tickets rather than growing the current change.
**Serialize board mutations when fanning out** — parallel implementation is fine, but
collect results and then loop `karr move`/`handoff`/`sync` sequentially.

## Release — never without permission

`dzil build` / `dzil test` are fine anytime. `dzil release` and any CPAN upload are STRICTLY
forbidden without the maintainer's explicit go-ahead — even if `TODO.md` or a ticket lists
"release" as the next step. For anything heading toward release: stop and ask.

## Hazards specific to this distribution

- **Tests never talk to a real router.** Everything goes through the injected `ua` mock
  in `t/lib/`. The optional live test is gated on `MIKROTIK_TEST_HOST` and is read-only;
  never set that variable yourself and never widen a test to depend on it. A router is
  production network gear — a stray `remove` or `set` is an outage, not a failed test.
- **`prove -l t/` is not recursive** and silently skips subdirectory tests, exiting 0. Use
  `dzil test` or `prove -lr t/`.
- **An untracked file does not exist as far as dzil is concerned.** `[@Author::GETTY]`
  gathers via `Git::GatherDir`; a new file that was never `git add`ed is absent from
  `dzil build` and the release tarball while `prove` happily runs it. `git add` new files
  as soon as they exist; `git status` is the last check before any release.
- **RouterOS values are strings, both directions.** `"disabled":"false"` is the wire
  contract. Do not add boolean/number coercion "for convenience" — it breaks round-trips
  and every consumer's `eq` comparisons. Send `JSON->true` and the router rejects it.
- **`PUT` is `add`, `POST` is a command.** A `POST` with a record body to a menu path is a
  406 from the router. The verb mapping in skill `perl-www-mikrotik` is the reference.
- **`.id` values (`*1A`) go into the path unencoded.** URL-escaping the `*` yields a 404
  that looks like "record not found".
- **Shared skills under `.claude/skills/` are hardlinks.** `Edit`/`Write` on one detaches
  it from the library silently. Only `perl-www-mikrotik` is owned here; everything else
  changes via `manage-skills` in its home repo.

## Perl conventions — reference, don't restate

Module loading, Moo patterns, typing, cpanfile pinning, POD directives and the
`@Author::GETTY` release flow live in skills `getty-perl-core`, `getty-perl-moo`,
`getty-perl-typing`, `getty-perl-release-author-getty` and `perl-release-dist-ini`
(force-loaded per lane via `briefing.skills`). Do not duplicate that content here.
