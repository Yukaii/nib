# Nib — agent guide

Single source of truth for how work happens here. Every agent (any vendor, any
model) follows it. Keep it under 200 lines; `scripts/check-workflow.sh` enforces
the limits.

## Mission

Nib turns an iPad + Apple Pencil into a **screen-off drawing tablet for a Mac**,
like a Wacom Intuos: the iPad screen stays black, the pen maps absolutely to a
Mac display, and Mac drawing apps (Krita, Photoshop, Affinity, Procreate
Dreams-style tools) receive real tablet events.

**Hard requirement:** Apple Pencil **pressure** must reach Mac apps as tablet
pressure. Tilt, hover and Pencil Pro squeeze come next. A change that loses
pressure is a regression, whatever else it gains.

Target hardware: iPad mini 6/7 (Pencil 2 / Pencil Pro), Apple Silicon Mac.

## Start here (every session)

1. Read this file, then `PLAN.md` (current milestone and next tasks).
2. Open the task you were given in `tasks/`, or pick the lowest-numbered
   `status: todo` task whose `depends` are all done.
3. `scripts/verify.sh` before changing anything. If it is red on a clean
   tree, fixing it is the first task.

## Ground rules

- The repo may become public. Never commit secrets, team IDs, provisioning
  profiles, or personal paths.
- Swift 6 language mode, strict concurrency. No third-party dependencies
  without a task that says so; prefer Apple frameworks (Network, CoreGraphics,
  UIKit, AppKit).
- Reference code: Glass (MIT, github.com/Ntarasiuk/glass) and Weylus may be
  read for ideas. Do not copy code without keeping the license header and
  noting it in Handoff.
- Keep disk usage small: no full clones of large repos; shallow clones go
  into `.cache/` (gitignored).
- Deterministic tests only. No network or hardware in `swift test`.
  Anything that needs a real iPad, Accessibility permission or a human
  watching Krita is a **manual check**: write the steps in the task's Handoff
  under "Manual checks" and say whether you ran them.
- Generated Xcode projects (`*.xcodeproj`) are not committed; `project.yml`
  (XcodeGen) is the source.

## Layout

```
AGENTS.md            workflow (this file)
PLAN.md              milestones, current focus, decisions index
tasks/               one file per open task; deleted when done
docs/                architecture.md, decisions/
Packages/NibCore/    shared Swift package: wire protocol, mapping, Mac injector
Apps/NibMac/         macOS menu-bar host app (receiver + event injection)
Apps/NibPad/         iPadOS app (screen-off pen capture + sender)
project.yml          XcodeGen spec for both apps
scripts/             verify.sh, check-workflow.sh
```

Platform-specific code in NibCore sits behind `#if os(macOS)` / `#if
os(iOS)` so `swift test` on the Mac covers everything testable.

## Commands

```bash
scripts/verify.sh            # the only gate: workflow, format, build, tests, app builds
swift test --package-path Packages/NibCore   # focused tests
xcodegen generate            # regenerate Nib.xcodeproj
```

Never pipe verify into `tail` without `set -o pipefail`.

## Definition of done

1. Every Acceptance item in the task file is satisfied and demonstrated.
2. `scripts/verify.sh` passes on the final commit; paste its last line in
   Handoff.
3. Behaviour changes have tests where testable without hardware.
4. No stray files, debug prints, or commented-out code.
5. The task's Handoff section is filled in.

## Tasks

File: `tasks/NNNN-short-slug.md`, four-digit id, never reused. Template:
`tasks/_template.md`. Frontmatter: `id`, `title`, `status`
(`todo|doing|review`), `milestone`, `depends`. Sections: `Goal`, `Context`,
`Acceptance`, `Out of scope`, `Handoff`.

- A task fits one focused session (roughly < 600 changed lines).
- Acceptance items are concrete commands or observable results.
- When merged, the task file is deleted in the same commit and ticked in
  `PLAN.md`. Git history is the archive.

## Roles and handoff

- **Orchestrator** — owns `PLAN.md`, `tasks/`, `AGENTS.md`; writes tasks,
  delegates, reviews, merges into `main`.
- **Worker** — implements exactly one task on its own branch/worktree. Does
  not edit `PLAN.md`, other tasks or `AGENTS.md`; does not push. If the task
  is wrong or blocked, stop and write why in Handoff.
- **Reviewer** — fresh context, never the implementer. Checks the diff against
  Acceptance and this file, reruns verify, reports file:line findings with a
  failure scenario. Does not rewrite the work.

Handoff happens through files and commits. A worker's final message and the
task's Handoff section both contain:

```
Branch/commit: <branch> @ <sha>
Verify: <last line of scripts/verify.sh>
Done: <1-5 bullets>
Manual checks: <steps; ran / not run>
Not done / risks: <skipped items, assumptions, follow-ups>
```

## Delegation (orchestrator)

Loop per task:

1. Commit the task file with `status: doing` on `main` (children only see
   commits).
2. Delegate in an isolated worktree with a prompt that says only: "Follow
   AGENTS.md. You are the Worker for `tasks/NNNN-*.md`." plus anything not in
   the task file.
3. Review with a different model than the worker (or the orchestrator, if it
   did not implement). On findings, send a new round with the original brief
   plus numbered findings; the new worker starts with
   `git merge --ff-only <previous-branch>`.
4. Merge `--no-ff` into `main`, delete the task file, tick PLAN.md, run
   verify, commit `chore(NNNN): done`.

Independent tasks may run in parallel; merge one at a time.

In T3 Code use `delegate_task` with `isolation: "worktree"`, `mode: "async"`,
a stable `clientRequestId` per round (`task-0002-r1`), and end the turn until
the completion notification arrives. Models (re-check with
`orchestrator_capabilities`; names change):

| Use                                    | Provider instance | Model                                                               |
| -------------------------------------- | ----------------- | ------------------------------------------------------------------- |
| Well-specified, mechanical tasks       | `opencode_2`      | `opencode-go/muse-spark-1.3-contributor`, `opencode-go/deepseek-v4.1-flash` |
| Harder implementation (platform APIs)  | `codex`           | `gpt-6.1-terra`                                                     |
| Review, fallback                       | `codex` / `claudeAgent` | `gpt-6.1-sol` / `claude-sonnet-5-5`                           |
| Orchestration, design, final review    | `claudeAgent`     | `claude-opus-5-5`                                                   |

Cheap models get tasks whose Acceptance is fully mechanical. If a cheap model
fails a task twice, escalate the model rather than loosening the task.

## Docs policy

- `docs/architecture.md` describes what exists now (≤ 150 lines).
- `docs/decisions/NNNN-*.md` only for choices expensive to reverse (wire
  protocol, transport, event injection method). ≤ 60 lines each.

## Code conventions

- Swift 6, `swift format` default style (verify runs `swift format lint`).
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`).
- Comments explain why, not what.
- Commits: conventional with task id, e.g. `feat(0003): tablet event injector`.
