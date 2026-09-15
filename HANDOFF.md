# Handoff

Written 2026-09-14, extended 2026-09-15. Everything below is verified against the code and
against this machine, not remembered.

## Where things stand

| Repo | Pushed | Tests |
|---|---|---|
| OpenWork-Swift | yes, `main` (`72b7f01`) | 437 |
| GrizzyBot | yes, `03eb11e` | 538 |

OpenWork went from 13 tests to 437 over this work. Released as 1.1.0.

---

## What landed since the previous handoff

Every item the previous handoff listed under "Do these" is done, plus the add-ons it listed.

**The built-in provider was never the default, and was not always the built-in provider.**

Two sources of truth disagreed. `defaultProviders` marks the Apple Silicon MLX provider
`isDefault: true`; `AppSettings.default` named `ollama-local` — a separate app that need not be
installed, rather than the engine compiled into the binary. On this machine that Ollama provider
was *also* disabled, so `ProviderSelection.resolve` fell through to its "first enabled in array
order" rule and landed on **`openrouter-cloud`**. A cloud provider was answering turns the user
believed were local, with `omlx-local` enabled three slots further down the array. That is a
privacy fault, not a preference one.

Routing is on `kind`, never on id — `ProviderRouter.client(for:)` switches on `.omlx`/`.vmlx` — so
any provider of that kind reaches the in-process engine whatever it is called. That matters
because the ids have drifted: the seed creates `builtin-mlx-local`, existing installs carry
`omlx-local`, and `PersistenceManager` still holds migration code renaming `.omlx` providers to
"Apple Silicon (Built-in)". Four tests now pin `AppSettings.default` and `defaultProviders` to the
same provider, and assert a fresh install cannot resolve to a cloud one.

**`.omlx` means in-process MLX and nothing else now.** `NativeMLXService.streamChat` used to fall
through, on any in-process failure, to probing ports 1337, 8000, 8080, 11434, 1234 and 5243 and
letting whatever answered serve the turn — reported as if the built-in engine had produced it. A
turn sent to "Apple Silicon (Built-in)" could be answered by Ollama. The branch for builds without
MLX linked did the same thing *unconditionally*, so a misconfigured build looked like it was
working. Both now run in-process or fail with the reason. Ollama, LM Studio and the rest lost
nothing: they are separate providers in the picker, chosen deliberately, through their own clients.

The provider's stored `baseUrl` (`http://127.0.0.1:8000/v1`) is dead and always was — the
in-process path never reads `provider`. It is left in place because `ProvidersView` already hides
the URL field for `.omlx`, so nothing can edit it into something misleading. **`ProviderKind.omlx`
is named after the third-party oMLX *server* app** and still carries its display name and port;
the "Apple Silicon (Built-in)" label users see comes from the migration, not the kind. Worth a
rename if anyone touches this again.

**The test suite was resetting the developer's own settings.** This is the answer to a mystery
this handoff recorded twice without solving: *"settings.json had reverted to an Ollama default at
some point and was set back"*. Nothing reverted. `SandboxContainmentTests` saved a fresh
`AppSettings.default` through the real `PersistenceManager.shared` — the running app's own
`~/Library/Application Support/OpenWorkSwift/settings.json` — and its `defer` "restored" another
fresh default. **Every full test run reset the real settings to stock.** It now captures and
restores what was actually there, and `SettingsAreNotClobberedByTestsTests` plants a sentinel to
prove the suite leaves the file intact.

**Any test using `PersistenceManager.shared` is touching live configuration**, not a fixture. Read
first, restore exactly, or use a temporary directory. This one cost two rounds of hand-editing and
a false lead about the MLX default.

**GrizzyBot is the reference for this subsystem.** Its Local MLX is a provider in the ordinary
rail with an enable toggle, no base URL (`mlx://in-process` is a sentinel nothing dials), one
routing branch (`Store.defaultClient` → `MLXChatClient` vs `OpenAIChatClient`), the model id as an
absolute bundle path, and `GrizzyBotMLXBootstrap.install()` at launch gating on arm64 and
colocating the metallib. It has no server concept for MLX, which is why nothing can quietly
substitute for it. OpenWork now matches on the parts that matter; the bundle-path-as-id idea is
still worth stealing.

**Local MLX found the weights that were already on disk.** This is the one that mattered: the
search roots named `/Volumes/Storage/Models` literally, and that path exists on no machine here.
The real library is `/Volumes/Models/Models`. Every lookup therefore missed a complete 35GB
`mlx-community/Ornith-1.5-35B-A3B-8bit`, and the chat turn fell through to fetching all 37.7GB
from Hugging Face — behind a status chip reading `Loading MLX weights: 20%`, which is
indistinguishable from loading a model you already have. A saved session showed 541MB of one shard
out of eight. `knownMLXSearchRoots` now sweeps the mounted volumes for the usual library folder
names instead of asserting one path: discovery went from nothing to 13 installed models, and
Ornith loads in 5s and answers.

The note below about `customMLXModelsDirectory` in "Settings changed on this machine" was the
early warning and was read as housekeeping. It was stale — the field reads `""` — and nothing
compensated for that, because the hardcoded root was wrong too. **A setting recorded there as
load-bearing is worth re-verifying against the machine, not just against the code.**

**A chat turn no longer downloads anything**, matching GrizzyBot's `MLXLocalGenerator`, which only
ever loads a local directory URL. A model that does not resolve fails immediately with a message
naming every root it searched, any partial download it found, and the models that *are* ready to
run. The old failure could not tell the user that the folder holding their weights was never on
the list.

**One download mechanism.** `pullModel` shelled out to `huggingface-cli` — a Python tool that is
not installed on a stock Mac, so the Local Models Download button could not succeed here at all —
and wrote to `~/.openwork/mlx_models/<org>--<repo>/`, a *different* directory from the one the
chat path's own downloader used, reporting progress as three hardcoded numbers (5%, 40%, 100%).
It now calls the same in-process `HubClient`, writing to the hub cache that
`resolveLocalModelDirectory` already searches, with real byte progress and resume on retry.

**The load watchdog is a size-derived budget, not a stall timer.** Timing silence only works when
the work reports progress, and `loadContainer(from:)` takes no progress handler — so with the
download gone the watchdog saw one tick and then nothing, and would have called every load over
180s wedged, including the 46GB Llama that loads in ~220s and works. The budget is now
`max(180s, weightBytes / 25MB per s)` — 1508s for Ornith — with a 10s heartbeat so a long load
looks alive rather than hung. Overrunning still costs only the one turn; the load keeps running
and populates the cache.

**One model resident at a time**, plus a cap on `MLX.Memory.cacheLimit`, as GrizzyBot's generator
does. Loading a second multi-gigabyte checkpoint beside the first is the fastest way to exhaust
unified memory. That cap was half of physical memory and is now the user's own GPU budget ratio —
see "The GPU budget slider moved a number nothing read" below.

**Three tests were passing for the wrong reason.** `LocalModelResolutionTests` called the real
engine with the real root list, so it only passed on a machine whose scanned roots held no models.
Name matching returns nil on ambiguity, so once discovery worked, a real library made correct code
fail. `resolveLocalModelDirectory` and `scanInstalledModels` take an optional `roots:` so a test
can state exactly where to look. **Any test that touches the file system through these should pass
its own roots.**

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

## What landed 2026-09-15

A sweep of all 57 settings fields for a control, a reader, and agreement between the two. Three
fixes, each verified live rather than by reading.

**The GPU budget slider moved a number nothing read.** `mlxGpuMemoryBudgetRatio` had a slider on
the MLX page, and its value rendered *in green* as "Safe GPU Memory Budget: 72.0 GB (75%)" there
and again in `ProvidersView`. Nothing read it. `NativeMLXService` capped MLX's buffer cache at a
hardcoded `cacheLimitFraction = 0.5`, and `assessCompatibility` judged which models fit against a
separate hardcoded `0.75`. The setting's default is 0.75, so the compatibility verdict agreed with
the readout exactly until someone moved the slider — which is why this survived the last sweep.
Same shape as the provider-default fault: a confident number with nothing behind it.

`applyMemoryPolicy(budgetRatio:)` and `assessCompatibility(requiredRAMGB:budgetRatio:)` now take
the ratio. **This changes runtime behaviour at the default**: MLX's cache limit goes from 50% to
75% of physical memory — 48GB to 72GB here — because 75% is what the UI has always claimed. Every
verdict the user sees is re-judged in `scanInstalledModels`, which is the one place holding both
the user's ratio and a list about to be displayed; `appState.localMLXModels` is fed only from
there. The curated catalog is a `static` with no access to settings and still bakes a verdict at
the shipped default, so **never display `curatedModels[i].compatibility` directly** — use
`judged(atBudgetRatio:)`. The slider re-judges on commit, not per step, because a rescan walks
every attached model volume.

Verified: `MLX.Memory.cacheLimit` read back `77309411328` after a real turn — 96GB × 0.75 exactly.

**The voice toggles gated nothing, and the feature they did not gate is real.** The previous
handoff filed `voiceInputEnabled`, `voiceSynthesisEnabled` and `speechVoiceIdentifier` as surface
for a planned feature. They are not: `ComposerView` draws a working mic button and
`MessageBubbleView` a working speak button, both unconditional. `speechVoiceIdentifier` defaulted
to Alex, had no control anywhere in the UI, and was never read — every utterance used
`AVSpeechSynthesisVoice(language: "en-US")`.

Both buttons now honour their toggles, `speak` resolves the stored identifier (falling back when
it names a voice this Mac has not downloaded), and the Extensions page has a voice picker with a
Preview button.

**Wiring a switch that did nothing can amount to deleting a feature.** Both toggles shipped
defaulting to `false`, so honouring a stored `false` literally would have removed the mic and
speak buttons from every existing install. A stored value from a switch that was never wired is
not a preference. Hence `AppSettings.settingsSchemaVersion` and
`PersistenceManager.applyMigrations`: version 2 turns both on for any file written before the key
existed, then stamps the version so a deliberate "off" sticks afterwards. **A migration must key
on the stored version, never on the values** — re-deriving "this looks unset" each load means the
user can never turn the setting off. There is a test for each direction.

Note the decoder subtlety: `settingsSchemaVersion` falls back to **1** when absent, not to
`def.settingsSchemaVersion`. Every other field in that initializer uses `def`; this one cannot, or
no existing file would ever migrate.

**Everything else on the sweep, in one pass.**

- **Two cards, not one.** `defaultTemperature`, `defaultMaxTokens` and `defaultReasoningEffort`
  seed the *new-agent sheet* — a turn reads `agent.temperature`, so dragging Temperature to 0.1
  for "precise coding" changed nothing about the agent answering. They sat under "Sampling
  parameters for autonomous LLM responses" beside Top-P and the penalties, which *are* read live
  per request. Split into "Defaults for New Agents" and "Sampling", with an **Apply to All
  Existing Agents** button so the values are reachable without creating an agent. The agent editor
  gained a Reasoning Effort picker — it was the only one of the three with no per-agent control.
- **Top-P reaches every provider.** It was read only by the in-process MLX path. Now sent by the
  OpenAI-compatible, Ollama and Anthropic paths too, and only when moved off 1.0 — 1.0 is a no-op,
  OpenAI advises against steering with temperature and top_p together, and Anthropic rejects
  `top_p` alongside extended thinking (hence the non-thinking branch only).
- **`contextCompactionThresholdTokens` got a control.** `AgentRunner` had always read it; the only
  way to change it was to hand-edit settings.json.
- **`useTranslucentBackground`** now puts an `NSVisualEffectView` behind the window, with the
  sidebar and inspector thinning their fills via `ThemeColors.paneBg(for:translucent:)`. Vibrancy
  needs both halves — an opaque pane over a material hides it completely, so wiring only the
  material would have looked like the switch was still broken.
- **`compactSidebar` and `showInterAgentCommunicationLogs`** had no control anywhere, not even a
  switch that did nothing. Both now have one and both do something: tighter sidebar rows and no
  workspace subtitle; the Agent Messages inspector tab hidden, with the selection moved off it so
  the inspector cannot render a tab the user just switched off.
- **`enableAgentCollaborationRoom`** gates the Multi-Agent Collaboration Room segment in AI
  Agents. It never gated `AgentCommunicationHub` and should not: that is delegation plumbing, not
  a room.
- **`AgentCommunicationHub`'s log had no readers and no bound.** `allMessages()` and
  `messages(for:)` are called from nowhere — the inspector reads `AppState.interAgentMessages`,
  a different store — so four call sites appended to an array nothing drained for the life of the
  process. Capped at 2000, oldest dropped.
- **`developerMode`** gates the Live Runtime Telemetry card and a new MLX Diagnostics card
  (resident models, the GPU budget in GB, and **every search root**). Those roots existed only
  inside a not-downloaded error message, which was on the "worth building next" list.
- **`verboseLogging`** had nothing to turn on: there was no verbose logging anywhere. `AppLog`
  now exists, gated on the setting, logging raw SSE payloads and tool call/result payloads to the
  unified log (`log stream --predicate 'subsystem == "ai.openwork"'`). `saveSettings` invalidates
  its cached gate, so the switch works without a relaunch.
- **`imageGenerationEnabled` reads the tools it writes.** It write-throughs to the `.mediaVision`
  category, so enabling one of those tools from the Tools page left the switch reading "off" while
  the tools were on — a switch reporting the opposite of the truth.
- **The version is the version.** The About row hardcoded "1.0.0" against a 1.1.0 release, and
  `project.yml` set no `MARKETING_VERSION`, so the bundle reported 1.0 as well. `MARKETING_VERSION`
  is now set and the row reads `CFBundleShortVersionString`. Verified: the built bundle reports
  1.1.0. **Bump it in `project.yml` on release.**
- **`autoCheckForUpdates` stopped promising.** The toggle toasted "Auto-check for updates enabled"
  beside a disabled button that correctly said checking is not implemented. Now disabled with a
  subtitle that says why.
- **Two hardcoded developer paths deleted.** `/Volumes/Storage/Models` was both the
  `customMLXModelsDirectory` default *and* a block in `AppState.loadAll` that wrote it into the
  user's settings whenever the path existed. The volume sweep is what finds the library; an empty
  field is not a gap to fill. The Updates page also loaded its icon from
  `/Volumes/Storage/Icons/…icns` with an `NSImage(named:)` fallback.

Verified after all of it: 13 models discovered with `customMLXModelsDirectory` empty, **6
compatibility verdicts change** between budget ratio 0.75 and 0.50, and a real turn answers while
rewriting none of settings.json, mcp_servers.json, providers.json or agents.json.

**Looking at the UI found a bug that compiling it could not.** Everything above was
compiler-verified, test-verified and exercised headlessly before the app was ever launched. It was
launched at the end, and the new voice picker rendered **completely blank**.

`speechVoiceIdentifier` shipped defaulting to `com.apple.speech.synthesis.voice.Alex` — an
*NSSpeechSynthesizer* identifier. Speech here goes through `AVSpeechSynthesizer`, whose
identifiers look like `com.apple.voice.compact.en-US.Samantha`; the default matched none of the
186 voices installed on this Mac. **A SwiftUI Picker whose selection matches no tag renders
nothing at all** — no placeholder, no first item, blank. Nobody could have noticed while the field
was unread, and the unit test for it passed: `preferredVoice()` correctly falls back, so speech
worked the whole time.

The default is now `""` (system default), the picker offers an explicit "System Default" row, and
`VoiceSpeechEngine.resolvedVoiceIdentifier` maps an unresolvable stored id to `""` so a legacy
value displays honestly. Normalised on read rather than migrated, because resolving a voice means
touching AVFoundation and `loadSettings` runs per turn.

**The lesson is the general one, not the voice one: a settings control verified only by the
compiler has not been verified.** Launch the app and look at the page.

**"Prefer local, never silently reach the network" is now the rule, and it was adopted
deliberately.** The previous handoff left this open on purpose, because it is a product decision
rather than a bug: `ProviderSelection.resolve` handed the turn to the first *enabled* provider in
array order when the selection was off, and on a typical configuration a cloud provider sits
earlier in that array than the local engine. Fixing `defaultProviderId` stopped it firing on a
fresh install; it stayed one toggle away for anyone who switched the built-in engine off.

A disabled **local** selection may now only be replaced by another **local** provider. When there
is none, `Resolution.mustRefuse` is true and the turn stops with a message naming the provider and
how to fix it, instead of answering over the network. A disabled *cloud* selection still falls
back as before — the rule is about not leaving local, not about never substituting.
`correctedSelectionId` follows the same rule at startup, or it would move the selection onto the
network before `resolve` ever got the chance to refuse.

Both turn entry points enforce it: `AppState.sendMessage` and `HeadlessAgentTurn.run`. The
headless path matters more, not less — a Shortcut or a Siri phrase runs with nobody watching, so
a silent substitution would never be noticed. `Resolution.overrodeDisabled` survives as a computed
property over the new `Outcome`, so the existing callers and tests are untouched.

**`loadSettings()` was a read that wrote.** Every branch ended in a write, including the
steady-state one, so it rewrote `mcp_servers.json` on every call — a synchronous atomic write,
under a lock, from the main thread among others — from 26 call sites including per turn, per tool
call, and six times over in `MCPProtocol`. Writes are now conditional on something having actually
changed; repairs and migrations still apply in memory on every load, so callers never see stale
values.

Proving it needed no instrumentation: `mcp_servers.json`'s mtime moved during a test that only
read settings. `LoadSettingsDoesNotWriteTests` pins it, and a real MLX turn now leaves
`settings.json`, `mcp_servers.json` and `providers.json` all untouched.

---

## What landed 2026-09-15 (second pass): the agent can see

Prompted by a question about what would make this a better app for vibe coding. The answer
came from the session's own evidence rather than from research: a settings picker was added,
402 tests passed, the compiler was happy, and it rendered **completely blank**. Only launching
the app and looking found it. The 2026 consensus agrees — VS Code 1.110 and Copilot both
shipped browser access for agents this year, and the visual feedback loop is the thing that
separates an agent that can check its work from one that cannot.

**Vision was declared everywhere and wired nowhere.** `supportsVision` on every `ModelInfo`,
`isVLM` detected from each model's `config.json` at discovery, `attachments` with a `mimeType`
on every `ChatMessage`, a "Vision OCR" extension in the UI — and every provider serialized
`msg.content`, a `String`, and nothing else. Exactly the fault class of the settings sweep
above, one layer up. `ImageTransport` now carries images to all four providers.

Two things to know before touching that path:

- **A `tool` message may not carry image blocks in the OpenAI schema**, so pixels follow as
  their own user turn. Anthropic *does* allow them inside `tool_result`, so there they stay
  attached to the call that produced them. The shapes genuinely differ; do not unify them.
- **`mergeToolMessagesIntoFollowingUser` rebuilds messages**, so it drops attachments unless
  told not to. The transport was undone one function later until that was fixed.

**`accessibility_tree` is the one to reach for first.** It reads a window as text: ~20× cheaper
than a screenshot, it states control *values* a screenshot only implies, and it works with a
**text-only model**. A vision-only feedback loop would abandon local MLX exactly where this app
is strongest. `screenshot_window` is for layout and colour.

Both need TCC permissions **per binary**, so the xctest runner has neither and cannot verify
them live — they are covered by their failure path, which names the exact System Settings pane.
To exercise them for real, grant Screen Recording and Accessibility to the built `OpenWork.app`
and drive them from the app. Screen Recording is only re-read at launch, so relaunch after
granting.

**Two bugs came out of running this against a real model, neither of which any test caught.**
This is the feature justifying itself on its first outing.

- **`run_app` terminated the app it launched**, so the two tools it exists to feed —
  `screenshot_window` and `accessibility_tree` — structurally could not see it. Ornith hit that
  within one turn: it launched the app, read "then terminated", and reasoned it would have to
  relaunch before inspecting anything. It now leaves the app **running by default**, with
  `quit_app` to clean up.
- **`AgentRunner` discarded a failing tool's entire `output`**, keeping only `error`. Any tool
  that fails *and* explains why lost the explanation. `run_app` returned `error: nil` for an app
  that exited non-zero, so the model received the literal string `Error: unknown error` with the
  exit code, stdout and stderr all thrown away. `describeToolResult` now keeps both, and a
  failure with no reason says so instead of claiming the reason is unknown. **This affected every
  tool, not just the new ones.**

**`run_app` closes the loop `build_project` and `run_tests` leave open.** Note the gotcha it
exists to remove: a child process started from a shell dies with that shell, so a hand-rolled
launch looks successful and is gone before anything inspects it.

**`git_commit` is confined to agent worktrees, and that is the whole design.** This is not the
session-wide undo that was rejected below — it is the opposite. Commits on a branch in a
directory of its own are additive history that cannot rewrite anything the user wrote. The
pinning test asserts that committing on the user's own checkout is refused *and* their log is
unchanged. Worktrees live *beside* the repo, never inside it, or the parent's status, build and
file search pick them up.

**Sub-agents take no tools** (`tools: []`) and never touch the filesystem — worth knowing before
anyone assumes worktrees isolate them. They are advisory LLM calls; they now run through a task
group instead of a serial loop, results applied in delegation order so the transcript is stable.

---

## What landed 2026-09-15 (third pass): sub-agents that do the work

**Sub-agents were theatre, and now are not.** `agent_spawn` built a `SubAgentTask`, returned
"Spawned sub-agent […] to execute task", and ran nothing. Auto-delegation made one call with
`tools: []` and a 512-token ceiling. `SubAgentExecutor` gives them a real ReAct loop with tools,
iteration and wall-clock budgets, unattended approvals, and a git worktree each.

**The parent now reads the result.** This was the actual defect: reports reached the Sub-Agent
Tree and the Agent Messages log and stopped — `workingMessages` never saw them, so the parent
answered as though nothing had been delegated. Work was done, displayed, and ignored by the only
participant who could act on it. Check this first if sub-agent output ever looks ignored again.

**`allowedToolIds` was a third dead control, and it bites anything that starts honouring it.** It
is shown in the Agents editor and stored on every agent; nothing read it until now. Its seeded
value predates most of the catalog — no grep, no edit_file, no build_project, no run_tests — so
respecting it as found would have crippled every sub-agent. The untouched seed is migrated to
empty ("everything the workspace allows"); a deliberately changed list is left alone. **Same shape
as the voice toggles: a value stored by a control that did nothing is not a preference.**

**Reasoning leaking into the answer is fixed, and the handoff's guessed fix was wrong.** It said
to "consume MLX's own reasoning channel where the model exposes one". There is no such channel —
`Generation` here is `.chunk`, `.info`, `.toolCall`. The mechanism is in the chat template: Ornith's
generation prompt ends with a bare `{{- '<think>\n' }}`, so the model begins generating *inside* a
block it never opened, and is meant to close with `</think>`. When it forgets, the text carries no
tags at all and `AssistantContentSanitizer` correctly refuses to guess. `ReasoningChannel` reads
the template, knows the block was pre-opened, and routes accordingly — determinate, not a heuristic.
Verified live: 212 characters of reasoning filed as reasoning, visible output exactly `SPLIT OK`.

**`NoDeadSettingsTests` is the sweep, as a test.** Two passes of `AppSettings` found ~20 switches
that changed a value and nothing else. A sweep is something you do once and stop doing, so it now
runs every build: every field needs a reader *and* a control, or an entry in `knownDead` with a
stated reason. It caught `autoCheckForUpdates` immediately.

---

## What is left

### Settings still dead

Four cloud fields — `cloudSyncEnabled`, `cloudControlPlaneUrl`, `cloudAccountEmail`,
`cloudOrganizationName` — plus `autoCheckForUpdates`. Every other field in `AppSettings` now has
both a control and a reader, pinned by tests.

These five are **not** an oversight, they are an unanswered product question. The cloud fields are
two whole settings pages for a feature that does not exist; `autoCheckForUpdates` is a switch for
an update feed that does not exist. Deleting them is a decision, not a cleanup, so they are left
with honest UI instead: the auto-check toggle is now disabled and says why, next to the Check
button that already did. `RemovedSettingsTests` shows how to delete a stored field safely when
the call is made.

`startOnLogin` is vestigial by design: the toggle reads `SMAppService` directly, because macOS is
the only authority on whether a login item is registered. The stored copy is written and never
read, which is correct.


### Worth building next

- **Local Models could still surface the search roots.** Settings › Debug now lists them, behind
  `developerMode`. A user whose library sits somewhere unusual has to find that page; the Local
  Models view itself is where they would look first.
- **Symbol-aware *rename*** on top of `SymbolIndex` — the index now knows where things are
  declared; the next hop is finding references safely.
- **Narrowed re-runs for more runners.** Only SwiftPM, `go test` and pytest can be narrowed.
  cargo and npm return nil, correctly, and stay whole-suite.
- **Notarised releases.** `OpenWork.zip` on the GitHub releases is ad-hoc signed, so macOS blocks
  it on first launch and users need right-click → Open. Local development builds are now signed
  (see the TCC note in Environment gotchas), but that self-signed certificate does nothing for
  distribution: this still needs your Developer ID Application certificate and an App Store
  Connect key for notarytool before the release workflow can be automated.

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

**Grep build output for `warning:`, not just `error:` — and do it after *every* change, not once.**
This was recorded after two `?? 0 ?? 0` warnings shipped, and then an unused `subAgentStartTime`
shipped anyway, because the sweep was treated as a one-off rather than a habit. The command that
keeps it honest, filtered to this project's own code:

```bash
$SWIFT build --build-tests 2>&1 | grep 'warning:' \
  | grep -vE 'swift-jinja|missing creator|mlx-swift'
```
 Two redundant `?? 0 ?? 0` warnings
shipped in the perception work because every build check in that session filtered for `error:`
alone. `attributesOfItem` throws *and* its subscript returns `Any?`, so the obvious inline
spelling is a `try?` around an `as?`, which yields a doubly-optional and invites exactly that
mistake — `ImageTransport.fileSize(atPath:)` is now the one place that does it.

**The loop breaker stopped covering reasoning the moment reasoning got its own channel.** It was
gated on `deltaText` being non-empty, which held while reasoning arrived inline in the visible
stream. Routing an unclosed `<think>` block to `deltaReasoning` left `deltaText` empty for the
whole turn, so the breaker never ran: an exported session shows **12,117 characters of reasoning
over 192.7 seconds with zero visible output**, stopped by hand. It now checks `fullReasoning` too.
Reasoning models spiral exactly where the visible text never grows, which is what the breaker was
built for — the guard and the thing it guards were separated by a later change to a different file.

**The thinking panel had no way to get text out of it** — not selectable, no copy button. That is
the one place holding the evidence when a turn goes wrong, and it could not be reported or
diagnosed. Both added.

**Dead-end detection only ever covered MCP.** `mcpDeadEnds` warns at 3 and disables MCP at 5, and
nothing equivalent existed for first-party tools — so one could fail identically forever. Observed:
a model called `screenshot_window` with the same arguments eight times and was still going when
the user stopped it by hand. `AgentRunner.callSignature` + `identicalFailureLimit` now refuse the
third identical failing call and tell the model why. Two, not one, because a single retry after a
transient failure is reasonable.

**`MLXVLM` was not linked, so vision models loaded as text-only.** `NativeMLXService` loaded every
checkpoint through `LLMModelFactory`, which builds a pipeline with no vision tower and no image
processor — images handed to it in `Chat.Message.images` are dropped in silence. The factory now
branches on `LocalMLXEngine.declaresVisionSupport`, and `MLXVLM` is a declared dependency in both
`Package.swift` and `project.yml`.

**`.contextMenu` on a container swallows text selection.** It was attached to the whole message
bubble, which installs a hit-testing region over the entire subtree and eats the mouse drag
`.textSelection(.enabled)` depends on — so replies were marked selectable, could not be selected,
and clicks aimed at the buttons inside the bubble were intercepted on the way. It now hangs off
the avatar. **Never put `.contextMenu` on a view that contains selectable text.**

**Changing the signing identity makes the Keychain treat the app as a stranger.** Signing with
the new certificate immediately hung the app at launch with no window: `AppState.loadAll()` →
`loadProviders()` → `KeychainManager.getSecret` → blocked on securityd, because a
differently-signed binary needs fresh authorisation for every stored item, and that happens on
the main thread *before the window exists*. `sample <pid>` is how to see it; a running
`SecurityAgent` process is the tell that a dialog is waiting somewhere.

Answer "Always Allow", once per item. Hydration now only queries **cloud** providers, so that is
one prompt rather than ten — local providers have no API key concept and were being queried for
one anyway.

**Ad-hoc signing silently kills TCC permissions on every rebuild.** This cost an hour and looks
like nothing else. With no Developer ID the app was ad-hoc signed, so macOS identified it by the
binary's *content hash*: each rebuild invalidated Accessibility and Screen Recording **while
leaving the app ticked in System Settings**. It reads "granted" and behaves "denied", and the
perception tools fail with a permission error you can see is already granted.

Fixed by signing local builds with a self-signed certificate — `Scripts/create-local-signing-cert.sh`,
run once. TCC then keys on the certificate, so grants survive rebuilds. `codesign -dvvv` should
report `Authority=OpenWork Local Signing`; if it says `Signature=adhoc`, the certificate is gone
and permissions will start decaying again.

**Changing to a stable certificate does not repair the existing entry** — the old grant points at
the old ad-hoc identity, so it must be removed and re-added once, after which it stays. In
macOS 26, Accessibility lives under **Privacy & Security › Device Control and Data Access**, not
a pane of its own.

**`swift-jinja` was declared and used by no target — and it was a version cap, not dead weight.**

Both manifests declared `swift-jinja` at `2.0.0..<2.4.0` while no target depended on it, which
is what the `dependency 'swift-jinja' is not used by any target` warning was about. Deleting it
is not obviously free: `swift-transformers` is the real consumer and declares `from: "2.0.0"`,
so the narrower range here was holding jinja down at **2.3.6** when 2.5.1 is published. Nothing
recorded why — it arrived inside a 1,000-file commit called "Update project configuration".

Checked before removing it, because Jinja is what `Tokenizers` uses to render **chat templates**,
which is every local MLX turn and something no unit test touches: forced to 2.5.1, the suite
passes and a real multi-turn MLX turn with a system prompt renders and answers correctly. So the
cap was not guarding a known break.

The declaration is gone from `Package.swift` and `project.yml`; **the resolved version is
deliberately left at 2.3.6** in both `Package.resolved` files. Jinja still builds and links
transitively through `Tokenizers`, so this changes nothing at runtime — bundling a dependency
bump into a warning fix would have been a separate decision wearing a cleanup's clothes.
**2.5.1 is verified good on this machine's model if anyone wants it**; that is a
`swift package update swift-jinja` away, and worth re-checking against a second model's chat
template first, since only Ornith's was exercised.

**`swift test` can fail with a missing `metal` compiler after a reboot.**

```
error: unable to spawn process '/var/run/com.apple.security.cryptexd/mnt/
com.apple.MobileAsset.MetalToolchain-v27.1.5194.15.EZDBV5/Metal.xctoolchain/usr/bin/metal'
```

The Metal toolchain is a cryptex whose mount point carries a random suffix that changes on
reboot, and XCBuild pins the old absolute path in its cached build description. `xcrun -f metal`
resolving fine while the build cannot spawn it is the tell. Clearing intermediates, `.build/out`
or the SwiftPM database does not help — the path lives here:

```bash
rm -rf .build/out/Intermediates.noindex/XCBuildData
```

**The project needs Xcode 26.6+ (Swift 6.3)** — `mlx-swift` declares
`swift-tools-version: 6.3;(experimentalCGen)`.

**A new source file needs `xcodegen generate`.** `Sources/Utils/AppLog.swift` was added this
pass; the `.xcodeproj` is tracked, so it must be regenerated and committed or the app target will
not compile the file even though `swift build` does.

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

Not in git, and **verified by reading `settings.json`, not remembered** — the previous version of
this table claimed `customMLXModelsDirectory` was `/Volumes/Models/Models` when the field was
actually empty, which is half of why local MLX appeared broken.

| Field | Actually reads | Note |
|---|---|---|
| `defaultProviderId` | `omlx-local` | The built-in in-process MLX engine. Routing is by `kind`, so the id drift against the seed's `builtin-mlx-local` does not matter. |
| `defaultModelId` | `mlx-community/Ornith-1.5-35B-A3B-8bit` | On disk, loads in ~3s. |
| `customMLXModelsDirectory` | `""` | Not load-bearing: `/Volumes/Models/Models` is found by the volume sweep. Set it only for a library somewhere else. |
| `customHFCachePath` | `""` | |
| `sandboxAgentFileSystem` | `false` | |
| `settingsSchemaVersion` | `2` | Stamped by the voice migration on 2026-09-15. Absent means 1. |
| `voiceInputEnabled` | `true` | Migrated from a stored `false` that no switch had ever controlled. |
| `voiceSynthesisEnabled` | `true` | As above. |
| `mlxGpuMemoryBudgetRatio` | `0.75` | Now load-bearing: it sets `MLX.Memory.cacheLimit` (72GB of 96GB here) and decides which models are badged as fitting. |

`providers.json`: two providers are enabled — `omlx-local` and `openrouter-cloud`. That pairing is
what made the default bug dangerous rather than merely wrong, because `openrouter-cloud` sits
*earlier* in the array and won the array-order fallback. Worth knowing if you disable `omlx-local`
while testing.

The model library on this machine is `/Volumes/Models/Models` (13 loadable bundles). Nothing is in
`~/.openwork/mlx_models/hub` — the abandoned 541MB partial Ornith download was deleted.

---

## Verifying a change

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
SWIFT=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift

$SWIFT test                    # 437 tests
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

It is cheap now, so there is no excuse for skipping it. A bare `NativeMLXService.shared.streamChat`
against `mlx-community/Ornith-1.5-35B-A3B-8bit` completes in about 5s — the 35GB bundle is mmapped
off `/Volumes/Models/Models`, not read through. That check is what showed the discovery bug was
real rather than theoretical, and what proved the fix: before, the same call started a 37.7GB
download; after, it answers.

Two gotchas when reading the output of such a run:

- **`streamChat` hands you the raw stream.** Reasoning models put their chain of thought straight
  into `deltaText`, sometimes closed with a bare `</think>` and sometimes not closed at all. Run it
  through `AssistantContentSanitizer.splitThinking` before judging what the user would have seen —
  the app does, and text that looks like a leak in a raw harness is usually not one.
- **A model whose `config.json` this `mlx-swift-lm` cannot parse fails at load, not at discovery.**
  `OsaurusAI/Raptor-v0.5-8B-A1B-JANG_6M` resolves fine and then reports
  `Missing field 'quantization.per_tensor.group_size'`. That is the model, not the lookup.

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
