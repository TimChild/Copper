# Voice — dictation in the agent pane

*Talk to the agent instead of typing. Speech is turned into text on this Mac by Fermion Research's
Phonon-2 on Core ML; audio is never saved or sent anywhere. Implementation: `Sources/Search/Fork/Voice/`
(`VoiceSession.swift` is the dictation, `VoiceKeys.swift` the shortcut, `VoiceUI.swift` the mic and the
line under the composer, `ComposerInsert.swift` where the words land, `VoiceEngine.swift` and `Phonon/`
the model runner, `ModelStore.swift` the download).*

## What it does

Voice lives in one place: the **⌘E agent pane**. Its composer gets a mic between the `/jev` button and
Send, and **⌃⇧D** dictates while the pane is open in the window you are typing in. The words go into the
agent's message — never into a web page, never into another app, never anywhere while the pane is closed.

While you talk the mic turns solid and one muted line above the composer's buttons says
*Listening…* with the newest words heard so far (two lines at most; a long dictation shows its end).
Those words are a guess that keeps changing, so they never go into the message itself. When you stop,
the line says *Finishing…* for the moment the last decode takes (about 40 ms for 5 s of speech, under
100 ms for half a minute on an M-series Mac), and the text lands at the caret the composer had when you
started — with a space before it unless it starts the message or follows a space. ⌘Z takes it back.

**Escape** (or the line's ✕) cancels: what was heard is thrown away and the message and its selection
are as they were. Closing the pane, closing or leaving the window, switching to another app, the Mac
going to sleep or the microphone failing cancel too. A dictation stops by itself after **2 minutes**.

## Settings › Voice

| Setting | Choices |
|---|---|
| **Voice** | Off by default. Turning it on downloads the speech model once (345 MB) and prepares it for this Mac's Neural Engine (about a minute, once). Off stops a download in flight and hides every trace of voice in the pane; the ⌃⇧D key then does nothing and reaches the page as usual. |
| **Talk** | **Hold to talk** — hold ⌃⇧D, or press and hold the mic; let go to stop. A tap shorter than a quarter of a second says *Hold to talk* and does nothing. **Press to start and stop** — ⌃⇧D or a click starts, the same again stops. |
| **When you stop** | **Insert into the message** — nothing is sent; read it and press Return. **Send right away** — the whole message is sent the way Return sends it, for a back-and-forth. If the agent is still answering (or isn't set up), the words are inserted and the line says *Inserted — press Return to send*; nothing is queued or lost. |

The mic tells you when it can't listen yet: dimmed while the model downloads (*Speech model downloading
· 42%*) or is prepared (*Preparing speech model — one time, about a minute*), or when it needs attention;
a click then opens Settings › Voice. It is greyed out while the agent has no model to talk to (*Sign in
with Claude or add a key to use the agent*).

## The microphone

macOS asks for the microphone the **first time you dictate** — never at launch, never for an agent.
In hold mode, a key let go while the question is up doesn't start a dictation once you answer. If the
answer was no, the composer says *Microphone access is off. Open System Settings to allow Copper, then
try again.* with a link to System Settings › Privacy & Security › Microphone. Copper's prompt text:
"Copper uses your microphone when you dictate to the agent, and when a website you allow asks for it.
Speech is turned into text on this Mac." (`build.sh`, `NSMicrophoneUsageDescription`).

## Privacy

- Audio and every word stay in memory for the length of one dictation and are then let go. Nothing is
  written to disk; nothing goes over the network. The logs carry counts and times only, never words.
- The partial line is never part of the message, and only the final text you see is ever sent — by you,
  or by *Send right away*.
- The model is loaded when the pane opens with voice ready (a third of a second once prepared) and let
  go again after 10 minutes without a dictation (100–200 MB of memory).

## The model

Phonon-2 Core ML (`FermionResearch/Phonon-2-CoreML`, pinned revision, every file SHA-256 checked) lives
in `~/Library/Application Support/Copper/Models/phonon-2-coreml/`, excluded from Time Machine. A
download a quit interrupts resumes at the next launch. **Settings › Voice › Remove** deletes it and turns
voice off. Voice needs **macOS 15** (the model is a multifunction Core ML package); on macOS 14 there is
no mic and Settings says why. Headless Copper never opens a microphone.

Speech model: [Phonon-2](https://huggingface.co/FermionResearch/Phonon-2-CoreML) by Fermion Research,
based on [NVIDIA Parakeet TDT 0.6B v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), CC BY 4.0.
The runner in `Sources/Search/Fork/Voice/Phonon` and `Sources/PhononTDT` is Fermion Research's
phonon-coreml (Apache-2.0; see its `NOTICE`).

## Checking it

Everything below runs in a probe world, with a sound file standing in for the microphone — no check
ever opens a mic or brings up the permission prompt (a test world refuses the real microphone unless
`SEARCH_VOICE_MIC=1`).

```sh
W=voice
defaults write com.officecommun.search.test.$W bench -bool true
defaults write com.officecommun.search.test.$W welcomed -bool true
defaults write com.officecommun.search.test.$W voice.enabled -bool true
open -n -g --env SEARCH_PROBE=$W --env SEARCH_HEADLESS=1 \
  --env SEARCH_VOICE_MODEL_DIR=/path/to/a/ready/model build/Copper.app

./bench --world $W voice selftest     # engine, live session, 15.00 s clip, composer insert, keys → failures []
./bench --world $W voice dictate clip.wav --trigger hold --finish insert --draft "Note: " --caret 6
./bench --world $W voice dictate clip.wav --trigger toggle --finish send     # sendCalled, sent
./bench --world $W voice dictate clip.wav --cancel-at 2                     # draftUnchanged, selection back
./bench --world $W voice source clip.wav && ./bench --world $W voice key down   # ⌃⇧D through the app…
./bench --world $W voice key up                                             # …and let go
./bench --world $W voice seed dictating && ./bench --world $W voice render /tmp/pane.png 340 dark
```

`voice dictate` answers with the state timeline (milliseconds from the press: partials as word counts,
release, decode, insert, send), the words inserted, the draft before and after, whether the message was
sent, and `release_to_insert_ms`. `voice seed idle|dictating|finishing|denied|preparing|downloading`
freezes the composer for pictures; `voice state` shows the phase, what the mic shows and how many ⌃⇧D
presses were taken or let through.
