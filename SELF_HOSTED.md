# Self-hosted build (espoogy fork)

This branch (`self-hosted`) is a private build of Dictus, signed with our own Apple ID.

## Security review (2026-10-30, upstream 1.9.0 / `0fd7badf`)

- **Keyboard extension: no network code.** Checked in the source and in the compiled
  binary (no NSURLSession, socket or Network.framework imports).
- **Main app network use:** voice-model downloads from `huggingface.co`, started by the
  user. Nothing else. (The App Store check is switched off in this fork.)
- **No analytics, crash reporters, ad SDKs or remote config.**
- **Libraries** (pinned in `Package.resolved`): WhisperKit 0.18.0, FluidAudio 0.15.8,
  DeviceKit 5.9.0, swift-transformers 1.1.9 and Apple/HF helpers. Their only network
  code is model download, which the app disables (`download: false`, `ModelHub.offlineMode`).
- **Prebuilt binary:** FluidAudio's `NemoTextProcessing.xcframework` (Rust text
  normaliser). It imports no network or file functions.
- **Private API:** `DictusKeyboard/HostAppResolver.swift` and `HostArbiterActivation.m`
  read which app you are typing in, to switch back after dictation. Logged on device only.
- **Full Access** is still needed. iOS gives the keyboard microphone access only with it.

## Fork changes

- App IDs: `io.aequari.dictus` (+ `.keyboard`, `.widgets`), App Group `group.io.aequari.dictus`.
- Team: `48932Y347G` (Personal Team, free; signature lasts 7 days).
- Pro is always on (History, Vocabulary). See `ProStatusManager.isProActiveStatic`.
- Smart Mode (Apple Intelligence rewrite) is hidden: `PremiumFlags.smartModeHidden`.
- StoreKit is not contacted at launch (`SubscriptionManager.init`).
- CarPlay: the warm mic is released 15 s after a dictation (`carRouteIdleReleaseInterval`).
  While Dictus holds a `.playAndRecord` session, CarPlay plays all phone audio like a call.
- Settings > Microphone > "Focus on my voice" (default on): Apple voice processing on the
  input node (`applyVoiceFocus`), AGC off, smallest extra ducking. It also unlocks
  Control Center > Mic Mode > Voice Isolation for Dictus.

## Auto re-sign every week

```
zsh scripts/self-hosted/install-autosign.sh            # install
zsh scripts/self-hosted/install-autosign.sh --remove   # remove
```

Once a day at 8 PM (or on wake) the Mac checks. If the last install is more than 4 days
old and the iPhone is on the same Wi-Fi, it builds this branch from GitHub and installs it.
In System Settings → General → Login Items it is listed as **Dictus AutoSign**.
Log: `~/Library/Application Support/DictusAutoSign/autosign.log`

## Get upstream updates

```
git fetch upstream
git merge upstream/main     # then review the diff before you push
```

## Live text while dictating (fork feature, step 1)

- Model: FluidAudio `StreamingUnifiedAsrManager`, Parakeet Unified 0.6B English,
  640 ms tier, int8 (`FluidInference/parakeet-unified-en-0.6b-coreml`, about 610 MB).
  Downloaded from Settings > Live text, with the same downloader as the other models.
- App: `DictusApp/Audio/LiveDictation.swift`. `UnifiedAudioEngine.onRecordedSamples`
  feeds it. It publishes the WHOLE transcript so far through `LiveTextChannel`
  (DictusCore) and a Darwin notification.
- Keyboard: `KeyboardState.syncLiveText()` inserts only the new tail. Its progress is
  saved in the App Group, so a restarted keyboard never inserts text twice.
- Rules: the model only appends. The keyboard never deletes or rewrites. At stop, the
  hand-off is marked live (`LiveTextChannel.markFinal`), so the keyboard inserts only
  the missing tail and skips polish and the normal full insert.
- Used only when: setting on, language English, model installed, dictation started
  from the keyboard. Otherwise Dictus works as before (Parakeet v3, text at the end).
- Logs: `LiveText` probes (counts only, never text) in the debug log.
- "Keep mic ready" (Settings > Live text) sets the idle window, default 30 min.
- Step 2: during a live dictation the keys stay on screen (`KeyboardState.syncAreaModeWithStatus`) and the toolbar mic is the stop button. The app begins the live session BEFORE it writes "recording", so the keyboard can tell.
- Watch item (memory): the app now holds Parakeet v3 and the streaming model in the
  background. If jumps to the app get MORE frequent, or the first live words after a
  break are slow, skip the Parakeet v3 preload when `LiveDictation.isUsable` and load it
  only as a fallback at stop.
- Known: the first live chunk has no leading space (same as the normal insert).
