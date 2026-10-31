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

## Auto re-sign every week

```
zsh scripts/self-hosted/install-autosign.sh            # install
zsh scripts/self-hosted/install-autosign.sh --remove   # remove
```

Every 4 hours the Mac checks. If the last install is more than 5 days old and the
iPhone is on the same Wi-Fi, it builds this branch from GitHub and installs it.
Log: `~/Library/Application Support/DictusAutoSign/autosign.log`

## Get upstream updates

```
git fetch upstream
git merge upstream/main     # then review the diff before you push
```
