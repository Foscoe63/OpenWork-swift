# Handoff

Written 2026-09-14. Everything below is verified against the code, not remembered.

## Where things stand

| Repo | HEAD | Pushed | CI |
|---|---|---|---|
| OpenWork-Swift | see `git log` | yes | green (208 tests) |
| GrizzyBot | `03eb11e` | yes | green (538 tests) |

Both working trees are clean. OpenWork went from 13 tests to 209 this session.

---

## README

Brought up to date in the same session (see git log). It now documents catalog promotion rather
than the deleted mail chain, lists the search / build / git / undo tools, and says plainly that
fail-closed classification means more approval prompts.

If you add a tool, add it to the Features table — every tool named there was verified to exist in
`ToolExecutionEngine` when this was written.

---

## Next: KV cache reuse — machinery landed, one blocker left

`MLXSessionReuse` + the caching in `NativeMLXService` are in and tested (17 tests). The decision
logic is correct and fails safe: anything it cannot prove is an append rebuilds the session.

**It does not yet deliver the speedup**, and the reason is precise.

`NativeMLXService.mergeToolMessagesIntoFollowingUser` merges a run of tool messages into the
*following* user message. While a tool result is the last message it renders as
`"[Tool output]\n<text>"`; once the next user message arrives, the same result re-renders as
`"<text>\n\n<user content>"`. The prefix is therefore recomputed on every call rather than
appended to, so reuse correctly detects divergence and rebuilds. Verified on a real turn:
`history diverged at message 5`.

**The fix**: make that merge append-only — always emit tool output as its own user message and
never fold it into the next one. Then the prefix only grows and reuse engages.

Do not "fix" this by fingerprinting the pre-merge messages. What the session consumed is the
*post-merge* text; if the merge changes retroactively the cache is genuinely stale, and comparing
pre-merge would claim reuse is safe when it is not.

Note the second reset seen on a real turn — `tool set changed` — is correct and unavoidable:
catalog promotion adds tools mid-turn, which changes the rendered prompt. Reuse resumes once the
tool set settles.

The measured prize, on Qwen3-Coder-Next-REAP-48B-A3B-mlx-8Bit (time-to-first-token):

| Turn | Fresh | Reused |
|---:|---:|---:|
| 2 | 1.52s | 0.89s |
| 3 | 2.22s | 0.90s |
| 4 | 2.86s | 0.90s |
| 5 | 3.53s | 0.91s |

Fresh grows ~0.67s per exchange and keeps growing; reuse is flat. This is a constant cost
replacing a linearly growing one, and in an agent loop the cost is paid per tool-call iteration,
not once per user turn.

---

## Then: 31 dead settings

42% of `AppSettings` (31 of 74 fields) is never read outside `Settings.swift` and the settings views. Reproduce with the sweep in the session log, or grep each field for `\.fieldName`.

Worth wiring:

- `mlxContextLength` — you have it at 262144 and nothing reads it. Maps to MLX's `maxKVSize`, **but** that switches to a rotating cache that silently overwrites old entries. A large value is harmless; a small one truncates context mid-session. Decide the semantics deliberately — don't pass it through quietly.
- `maxGlobalSubAgentDepth`, `allowSubAgentCreation` — unenforced; depth is hardcoded `1` at `AgentRunner.swift:554`.

Worth deleting rather than wiring: `streamResponses`, `uiScalePercent`, `playNotificationSounds`, `startOnLogin`, and the cloud-sync fields. `defaultTemperature` / `defaultMaxTokens` are dead because agents carry their own — either seed new agents from them or remove them from the UI.

A switch that does nothing is worse than no switch.

---

## Add-ons worth building

- **Symbol-aware search** on top of `CodeIndex` — index declarations so "where is X defined" is one hop.
- **Multi-edit** — several `old_string`/`new_string` pairs per file in one call, applied atomically. Local models burn turns on sequential single edits.
- **Re-run only failing tests** — `BuildDiagnostics` already parses failures; feeding `--filter` back tightens the loop.
- **Session-scoped change review** — per-turn exists; per-session is the natural next step.

---

## Reviewed proposals — my recommendation

A list of improvements was proposed at the end of the session. Assessed against the code; ranked
by value per unit of risk. Detail matters here, so the reasoning is kept.

### Do these

**1. Milestone-driven compaction.** Best of the set. Today `ContextCompactor` triggers on token
count alone, which can fire mid-task and discard working memory. Trigger it instead after a
*milestone* — a green `run_tests`, a clean `git_status` — when history is most disposable and the
digest is most meaningful. This adds a trigger to existing machinery, not new machinery. Keep the
current objective: compaction already preserves the first user message for exactly this reason.

**2. Close three gaps in the path sandbox.** `sandboxDenial` already gates every file tool
including `grep`/`glob`, and `standardizingPath` does resolve `../../../etc/hosts`. But:

- `sandboxAgentFileSystem` defaults to **false** — the protection ships disabled.
- `standardizingPath` resolves `..` but **does not follow symlinks**. A symlink inside the
  workspace pointing at `/etc` passes the prefix check. Fix with `resolvingSymlinksInPath()`.
  (This same class of bug appeared twice in new code this session.)
- `terminal_command` is gated by `terminalSafetyLevel`, not by path. Under `.allowAll` a shell
  command writes anywhere, and `cwd` is never validated.

Smaller than building a new wrapper, and one of the three is a live bypass.

**3. App Intents / Shortcuts.** Strong native differentiator and the Automations engine already
exists. Settle one design question first: what happens when an unattended, Siri-triggered agent
hits an approval gate? Refuse-and-report is the safe default.

**4. Fork / time-travel from a turn.** High value — "80% right, one bad turn" is the real pain.
Scope it honestly: `FileCheckpointStore` is *deliberately* turn-scoped (`beginTurn` discards the
prior window, because an agent that can silently roll back ten turns is worse than one that cannot
roll back at all). Forking reopens that decision. And forking file state without forking **message
state** is incoherent — you would restore files to turn 4 while the transcript still claims turn 5
happened. Both must branch together, which makes this a session-model change, not a checkpoint
change.

### Do not do these

**JSON repair middleware that balances braces.** The failure mode is real for local models, but
brace-balancing is dangerous for mutating tools: if `file_write`'s `content` is truncated
mid-string, appending `"}` yields *valid JSON with silently truncated file content* — a half-written
file reported as success, which is the exact failure class this session was spent removing. Repair
turns a loud failure into a quiet corruption.

Also note the proposed integration point does not exist: `ToolSchemaCatalog` hands schemas outward
and never receives payloads. Arguments are parsed in `ToolExecutionEngine.execute`, which already
has a repair layer (`coerceJSONMaps`, `parseObjectMap`, `sanitizeToolArgumentsJson`, plus a retry
for stringified maps).

If you pursue it: log parse failures first and confirm it is happening — one *shape* failure was
observed this session and zero truncations — then repair only provably safe cases (unbalanced
braces with no string literal open) and **never** for tools that write.

**Loading `.dylib` plugins from `~/.openwork/plugins`.** The motivation given was IPC latency.
Measured this session: MCP round-trips are milliseconds, model prefill is *seconds* (1.5s → 3.5s
and climbing). IPC is not within an order of magnitude of being the bottleneck.

The cost is steep: arbitrary code execution inside the app process, inheriting its TCC grants —
Info.plist requests Accessibility, Screen Recording, Contacts, Calendar and Microphone — plus
Keychain access, with no approval gate and no revocation, and it would force weakening library
validation in the hardened runtime. MCP's process isolation is a feature, not overhead. A plugin
that needs speed can be a local MCP server written in Swift: same language, same performance,
still isolated.

**Desktop widgets** — lowest value here. Needs a new extension target and a shared App Group
container (settings live in Application Support today), and a widget can only display state, not
run agents. Real plumbing for modest payoff.

---

## Known issues not fixed

**GrizzyBot's committed `project.pbxproj` omits `McpSessionPool.swift`.** CI hides it by running `xcodegen generate` first, so it stays green while opening the project in Xcode gives a broken build. Run `xcodegen generate` there and commit.

**GrizzyBot's four `GrizzyBotUITests` fail for environmental reasons, not code.** A bare `WindowGroup { Text("…") }` with none of GrizzyBot's code fails identically under XCUITest, while the same binary shows its window fine via LaunchServices. Two separate blockers: CI passes `CODE_SIGNING_ALLOWED=NO`, which kills the runner before it connects (`signal kill before establishing connection`); locally it looks like missing Accessibility permission for the test runner. The CI comment calling it "a real bug" is, as far as I could determine, wrong.

**MLX container teardown segfaults at process exit** (signal 11) after tests pass. Cost me a benchmark run's output, since `print` to a pipe is buffered and never flushed. Write benchmark results to a file, not stdout.

---

## Environment gotchas

**`swift build` crashes in the manifest compile.** `xcode-select` points at CommandLineTools while a swift-6.3 toolchain is active. Every command in this session used:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test
```

Permanent fix needs your password:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

**The project needs Xcode 26.6+ (Swift 6.3).** `mlx-swift` declares `swift-tools-version: 6.3;(experimentalCGen)`. CI selects the newest Xcode on the image rather than pinning.

**CI cancels superseded runs.** `cancel-in-progress: true` means pushing again cancels the previous run. Fine normally — the tip covers everything — but it hides per-commit verification if you're bisecting.

---

## Two settings changed on this machine

Not in git; backups were in the session scratchpad, which is gone. Both were stale rather than deliberate.

| File | Field | Was | Now |
|---|---|---|---|
| `settings.json` | `customMLXModelsDirectory` | `/Volumes/Storage/Models` (empty) | `/Volumes/Models/Models` |
| `providers.json` | `lmstudio-local.isEnabled` | `false` | `true` |

---

## Verifying a change

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
SWIFT=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift

$SWIFT test                    # 208 tests
xcodegen generate              # after adding files — the .xcodeproj is tracked
```

A real agent turn against the local model, without the GUI, is the highest-signal check —
drive `AgentRunner.shared.run(...)` from a temporary test with `omlx-local` and
`PersistenceManager.shared.loadSettings().defaultModelId`. That pattern found four bugs this
session that the unit tests could not, because each depended on the shape of real data:
promotion picking the wrong array, a 40KB catalog truncated before parsing, a string where a
list was expected, and a model id that matched no folder.

Delete the temp test afterwards.
