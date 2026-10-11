# Design

Local Dictation is built around one requirement: the moment you press fn, it's listening.
Accuracy has to match a cloud dictation service, and nothing may leave the Mac.

## Where start-up latency comes from

Cloud dictation apps typically open the microphone when you press the key and close it when
you stop. Opening an audio device is never free, and with Bluetooth headsets it is slow: the
headset has to switch from its music profile to a call profile (HFP), which takes 1–2 s.
Nothing can be captured until that finishes, and the first word is often clipped.

Electron-based apps add more: the key event crosses several processes (native helper → main
process → renderer that owns the mic) before recording starts.

## Architecture

One native Swift process. Nothing on the hot path crosses a process boundary.

```
fn key ──► CGEventTap (listen-only)
                │ key-down: mark position in ring buffer, show overlay, play cue
                ▼
built-in mic ──► AVAudioEngine (always running) ──► 16 kHz ring buffer (0.3 s pre-roll)
                                                         │
                     pause detected (600 ms quiet) ◄─────┤ segments cut while you talk
                                                         ▼
                              Parakeet TDT 0.6B v3 on the Neural Engine (FluidAudio)
                                                         ▼
                              cleanup LLM, LFM2.5 1.2B fine-tune (llama.cpp, Metal)
                                                         ▼
           text rules: dictionary · names on screen · spacing/capitalization at the cursor
                                                         ▼
                              paste via pasteboard + ⌘V, previous clipboard restored
```

1. **Audio**: the built-in mic is opened once at launch and kept running. Samples go into
   a ring buffer; while idle only the last 0.3 s is kept. Key-down marks the start of a
   take, including that pre-roll, so the first syllable is never lost. The built-in mic is
   the default so headsets never switch into call mode.
2. **Hotkey**: a listen-only event tap watches Fn (key code 63). Hold for push-to-talk,
   double-tap for hands-free, Esc to cancel. Fn used with another key is treated as a chord
   and cancels.
3. **Streaming segments**: while you talk, audio is cut at natural pauses and each segment
   is transcribed and cleaned in the background. On release only the last segment is
   still pending, so long dictations don't take longer to land.
4. **Speech recognition**: Parakeet TDT 0.6B v3 (CoreML, Apple Neural Engine) through
   FluidAudio. Loaded and warmed at launch.
5. **Cleanup**: a 1.2B model fine-tuned on the user's own history of raw → cleaned
   dictations removes filler words, fixes punctuation and handles self-corrections. A guard
   rejects output whose length drifts too far from the input. See
   [`training/`](../training/README.md).
6. **Context**: at key-down, the focused text field is read through Accessibility (250 ms
   timeout). Text that continues a sentence starts lowercase, spacing is fixed on both sides,
   and names on screen correct close misspellings.
7. **Insert**: the clipboard is saved, the text pasted with a synthetic ⌘V, and the clipboard
   restored half a second later.

## Measured

On an M5 MacBook Air, with 130 held-out real-world recordings (44 minutes):

| Stage | Result |
|---|---|
| Key-down to recording | ~50 ms (and 0.3 s of pre-roll is already buffered) |
| Speech recognition, clips ≤ 20 s | 0.09 s median on the Neural Engine |
| Release to paste | ~220–280 ms typical |
| Model load at launch | ~0.3 s ASR, ~0.5 s cleanup |

Speech recognition models compared (word error rate against the cloud service's raw transcript):

| Model | WER | Median time, clips ≤ 20 s |
|---|---|---|
| Parakeet TDT 0.6B v3, FluidAudio (Neural Engine) | **3.2 %** | **0.09 s** |
| Parakeet TDT 0.6B v3, MLX (GPU) | 4.1 % | 0.38 s |
| Whisper large-v3-turbo, MLX (GPU) | 8.0 % | 1.14 s |

Parakeet variants v2, ultra and phonon2 scored within noise of v3 (3.2–3.5 %).
Cleanup model results are in [`training/README.md`](../training/README.md).

## Decisions

- **Native Swift instead of Electron.** The hot path is a key event, an audio buffer and a
  paste; a browser runtime adds processes and hops to all three.
- **Always-open mic.** Instant start and pre-roll in exchange for the orange mic indicator
  staying on. Audio is only processed during a take.
- **llama.cpp for the LLM.** MLX would also work, but its Swift package needs Xcode's Metal
  compiler; llama.cpp ships a prebuilt framework with embedded Metal kernels, so the app
  builds with the Command Line Tools alone.
- **Fine-tuned 1.2B over a prompted 4B.** Better accuracy at under half the latency, and it
  never rewrote or dropped content in testing.
