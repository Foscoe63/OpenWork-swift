# Handoff

Written 2026-09-14. Everything below is verified against the code at `b5fc02b`, not remembered.

## Where things stand

| Repo | HEAD | Pushed | CI |
|---|---|---|---|
| OpenWork-Swift | `b5fc02b` | yes | green (193 tests) |
| GrizzyBot | `03eb11e` | yes | green (538 tests) |

Both working trees are clean. OpenWork went from 13 tests to 193 this session.

---

## README

Brought up to date in the same session (see git log). It now documents catalog promotion rather
than the deleted mail chain, lists the search / build / git / undo tools, and says plainly that
fail-closed classification means more approval prompts.

If you add a tool, add it to the Features table — every tool named there was verified to exist in
`ToolExecutionEngine` when this was written.

---

## Next: KV cache reuse (measured, worth doing)

`NativeMLXService.streamInProcess` builds a fresh `ChatSession(container, history:)` every turn, so MLX re-prefills the whole conversation each time.

Measured on Qwen3-Coder-Next-REAP-48B-A3B-mlx-8Bit, time-to-first-token:

| Turn | Fresh (today) | Reused |
|---:|---:|---:|
| 2 | 1.52s | 0.89s |
| 3 | 2.22s | 0.90s |
| 4 | 2.86s | 0.90s |
| 5 | 3.53s | 0.91s |

Fresh grows ~0.67s per exchange and keeps growing; reuse is flat. The headline "3.6× overall" understates it — this is **a constant cost replacing a linearly growing one**. A long coding session is where it bites.

MLX supports it directly: `ChatSession.streamDetails(to messages: [Chat.Message])` is documented as continuing a session *"while preserving the session's KV cache"* — the agent loop's exact shape.

Two things to get right, both able to cause silent wrongness:

- **Invalidation.** The cache is valid only while the prefix is stable. `ContextCompactor` rewrites history mid-session; a model, instructions or settings change invalidates it. Stale context silently steering output is worse than being slow — reset the session whenever the prefix diverges.
- **Memory.** A retained KV cache is not free alongside 48GB of weights in 96GB.

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

$SWIFT test                    # 193 tests
xcodegen generate              # after adding files — the .xcodeproj is tracked
```

A real agent turn against the local model, without the GUI, is the highest-signal check —
drive `AgentRunner.shared.run(...)` from a temporary test with `omlx-local` and
`PersistenceManager.shared.loadSettings().defaultModelId`. That pattern found four bugs this
session that the unit tests could not, because each depended on the shape of real data:
promotion picking the wrong array, a 40KB catalog truncated before parsing, a string where a
list was expected, and a model id that matched no folder.

Delete the temp test afterwards.
