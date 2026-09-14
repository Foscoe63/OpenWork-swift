# Handoff

Written 2026-09-14. Everything below is verified against the code, not remembered.

## Where things stand

| Repo | Pushed | Tests |
|---|---|---|
| OpenWork-Swift | yes, `main` | 362 |
| GrizzyBot | yes, `03eb11e` | 538 |

OpenWork went from 13 tests to 362 over this work. Released as 1.1.0.

---

## What landed since the previous handoff

Every item the previous handoff listed under "Do these" is done, plus the add-ons it listed.

**KV cache reuse actually engages.** `mergeToolMessagesIntoFollowingUser` is append-only now, so
the prefix only grows; and the comparison is a two-pointer walk that lets the session's *trailing*
generated reply have no counterpart in the caller's transcript. Verified live: zero divergence
rebuilds. The one remaining reset — `tool set changed` from catalog promotion — is correct and
unavoidable.

**Filesystem containment.** `canonicalPath` resolves symlinks (a link inside the workspace pointing
at `/etc` used to pass the prefix check); `terminal_command` redirects, `tee` and mutating commands
are gated by path plus `cwd`; `sandboxAgentFileSystem` defaults to true for *new installs only* —
an existing settings.json keeps its stored value, pinned by a test.

**Milestone-driven compaction.** A green `run_tests` / `build_project`, or a `git_status` reporting
a clean tree, now triggers compaction as well as token pressure. `isMilestone` requires the call to
have succeeded *and* the output to corroborate it, because a build can exit zero and still print
errors.

**Shortcuts and Siri.** `AskOpenWorkIntent` and `RunAutomationIntent` run the same `AgentRunner`.
The design question they turn on is settled: an unattended run refuses approvals instead of
awaiting them, records what it refused, and reports it. `requestApproval` returns an outcome rather
than a Bool so "the user said no" and "nobody was asked" cannot be conflated.

**Fork a conversation** from any message. Conversation state branches; the working tree does not,
and the fork says so by naming every file the discarded turns touched. `FileCheckpointStore` stays
turn-scoped on purpose.

**multi_edit** — several edits to one file, all or nothing, gated exactly like the tools it
replaces (approval, plan mode, checkpoint, sandbox, digest). **`run_tests(only_failing: true)`** —
failures parsed into identities (XCTest, go, pytest) and turned back into a narrowed command;
returns nil rather than a flag an unknown runner might ignore. **find_symbol** — declaration index
for Swift, Python, JS/TS, Go, Rust, Ruby, Java/Kotlin. **Session-wide change review** — read-only,
built from the transcript, with git supplying the diff.

**Settings.** 30 of 81 fields were never read. Sub-agent gating, agent defaults, editor font,
launch-at-login (real `SMAppService`) and the turn-finished sound are now wired; `streamResponses`,
`autoSaveIntervalSeconds`, `uiScalePercent` and `mlxContextLength` were removed. "Check for
Updates" no longer claims you are on the latest version without checking.

**Loop breaking.** `autoLoopBreakerEnabled` detected repetition and then waited for the stream to
finish — so a real 35B run spiralled for 219 seconds and its whole token budget with the setting
on. The stream is now cancellable from the streaming callback, the check watches reasoning as well
as visible text (reasoning models spiral where the visible text never grows), it is sampled every
24 tokens against the tail rather than re-split per token, and it tells the user it cut the answer
off. A turn that produced only reasoning also no longer renders as an empty bubble.

---

## What is left

### Settings still dead (verified by sweep, not memory)

`defaultReasoningEffort` is wired for *new* agents only. Still unread:
`useTranslucentBackground`, `compactSidebar`, `showInterAgentCommunicationLogs`,
`enableAgentCollaborationRoom`, `voiceInputEnabled`, `voiceSynthesisEnabled`,
`speechVoiceIdentifier`, `imageGenerationEnabled`, `developerMode`, `verboseLogging`, and the
cloud fields (`cloudSyncEnabled`, `cloudControlPlaneUrl`, `cloudAccountEmail`,
`cloudOrganizationName`, `autoCheckForUpdates`).

These are left deliberately rather than deleted: several look like surface for planned features
(voice, image generation, the collaboration room), and the cloud fields are two whole settings
pages. Deleting those is a product decision, not a cleanup — it needs your call, not mine.

### Worth building next

- **Symbol-aware *rename*** on top of `SymbolIndex` — the index now knows where things are
  declared; the next hop is finding references safely.
- **Narrowed re-runs for more runners.** Only SwiftPM, `go test` and pytest can be narrowed.
  cargo and npm return nil, correctly, and stay whole-suite.
- **Notarised releases.** `OpenWork.zip` on the GitHub releases is ad-hoc signed, so macOS blocks
  it on first launch and users need right-click → Open. This machine has no signing identity
  (`security find-identity -v -p codesigning` reports none) and no notarytool profile, so it needs
  your Developer ID and an App Store Connect key before the release workflow can be automated.

### Explicitly decided against — with reasons, so they are not re-proposed

**JSON repair that balances braces.** If `file_write`'s `content` is truncated mid-string,
appending `"}` yields valid JSON with silently truncated file content — a half-written file
reported as success, which is the exact failure class this work removed. `ToolExecutionEngine`
already has a repair layer (`coerceJSONMaps`, `parseObjectMap`, `sanitizeToolArgumentsJson`). If
you pursue it: log parse failures first, then repair only provably safe cases, and **never** for
tools that write.

**`.dylib` plugins.** The motivation was IPC latency. Measured: MCP round-trips are milliseconds,
model prefill is seconds. Cost is arbitrary code execution inside the app process, inheriting its
TCC grants (Accessibility, Screen Recording, Contacts, Calendar, Microphone) plus Keychain, with no
approval gate and no revocation. A plugin that needs speed can be a local MCP server in Swift.

**Desktop widgets.** New extension target plus a shared App Group container, and a widget can only
display state, not run agents.

**Session-wide undo.** `FileCheckpointStore.beginTurn` discards the prior window on purpose. An
agent that can silently revert ten turns of your work is worse than one that cannot revert at all.
The session-wide *review* exists; it deliberately offers no revert.

---

## Known issues not fixed

**GrizzyBot's committed `project.pbxproj` omits `McpSessionPool.swift`.** CI hides it by running
`xcodegen generate` first. Run `xcodegen generate` there and commit.

**GrizzyBot's four `GrizzyBotUITests` fail environmentally, not from code.** A bare
`WindowGroup { Text("…") }` with none of GrizzyBot's code fails identically under XCUITest, while
the same binary shows its window fine via LaunchServices. CI passes `CODE_SIGNING_ALLOWED=NO`,
which kills the runner before it connects; locally it looks like missing Accessibility permission
for the test runner.

**MLX container teardown segfaults at process exit** (signal 11) after tests pass. `print` to a
pipe is buffered and never flushed, so write benchmark results to a file, not stdout.

---

## Environment gotchas

**`swift build` crashes in the manifest compile** unless the Xcode toolchain is selected:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift test
```

Permanent fix needs your password: `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`

**The project needs Xcode 26.6+ (Swift 6.3)** — `mlx-swift` declares
`swift-tools-version: 6.3;(experimentalCGen)`.

**App Intents are validated at build time by the real app target, not by `swift build`.** A phrase
interpolating a `String` parameter is a halting error there and invisible to SwiftPM. After
touching `Sources/App/Intents`, run:

```bash
xcodegen generate && xcodebuild -project OpenWorkSwift.xcodeproj -scheme OpenWorkSwift build
```

**CI cancels superseded runs** (`cancel-in-progress: true`), which hides per-commit verification if
you are bisecting.

---

## Settings changed on this machine

Not in git. `settings.json` had reverted to an Ollama default at some point and was set back:

| Field | Now |
|---|---|
| `customMLXModelsDirectory` | `/Volumes/Models/Models` |
| `defaultProviderId` | `omlx-local` |
| `defaultModelId` | `DreamFoundries/Qwen3.6-35B-A3B-8bit` |

`providers.json`: `lmstudio-local.isEnabled` was flipped to true earlier; it currently reads false
again. `omlx-local` is enabled, which is the one that matters for in-process MLX.

---

## Verifying a change

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
SWIFT=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift

$SWIFT test                    # 362 tests
xcodegen generate              # after adding files — the .xcodeproj is tracked
xcodebuild -project OpenWorkSwift.xcodeproj -scheme OpenWorkSwift build   # App Intents metadata
Scripts/check-curated-models.sh   # after editing the curated model list
```

That last one is a script rather than a test because it asks a remote host what exists, and CI
should not go red because Hugging Face is rate-limiting. It is worth running periodically even
without a code change: five of the fifteen curated ids had rotted into 401s, so the app was
offering downloads that could not succeed.

A real agent turn against the local model, without the GUI, is the highest-signal check — drive
`AgentRunner.shared.run(...)` from a temporary test with the provider and model in settings. That
pattern found four bugs that unit tests could not, because each depended on the shape of real data:
promotion picking the wrong array, a 40KB catalog truncated before parsing, a string where a list
was expected, and a model id that matched no folder.

Write its output to a file — `print` to a pipe is lost when MLX segfaults at exit. Delete the temp
test afterwards.

Two things that only a real run shows, both now fixed but worth knowing the shape of:

- **Wrap the run in `ToolApprovalManager.shared.withUnattendedApprovals`.** Without it the turn
  blocks forever the first time the model calls a writing tool, because nothing is on screen to
  approve it. A refused call still records the arguments the model produced, which is usually what
  you wanted to see anyway.
- **Local models send structured arguments in whatever shape they like.** The 35B model sent
  `multi_edit`'s `edits` as a JSON *string* rather than an array. Parsers for new tools should
  accept the obvious variants and reject the rest, rather than guessing.
