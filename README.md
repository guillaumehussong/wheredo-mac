# Wheredo (macOS)

**Wheredo shows you where to click.** Press **⌘$**, ask a question out loud — Wheredo looks at your screen, answers with voice, and points at the exact spot with a red guide cursor.

Powered by [xAI's Grok](https://x.ai) (vision, speech-to-text, text-to-speech). Requires a SuperGrok or X Premium account.

> Looking for Windows or Linux? See [wheredo-desktop](../wheredo-desktop) — a Tauri app with the same features and the same configuration.

## How it works

1. Press **⌘$** and speak your question.
2. Wheredo captures the active window, says *"Let me take a look…"*, and sends the screenshot + your question to Grok.
3. Grok answers out loud and a **red guide cursor** appears on the control it's talking about.
4. If you asked Wheredo to click for you, it asks for confirmation first — it never clicks silently.

## Install

Requires macOS 14+ and Xcode command line tools.

```bash
./scripts/install-app.sh --setup
```

This builds the app, installs it to `~/Applications/Wheredo.app`, signs it with a stable identity (so permissions survive rebuilds), and walks you through the Microphone / Screen Recording / Accessibility permissions.

Then sign in:

```bash
./run.sh --login
```

## Usage

Wheredo lives in the menu bar. Press **⌘$** (or menu bar → *Speak now*) and talk.

CLI mode:

```bash
./run.sh "How do I open the settings in this app?"   # text question
./run.sh --no-speak "…"          # without voice playback
./run.sh --test-capture          # diagnose screen capture
./run.sh --setup-permissions     # full permission wizard
```

## Configuration

Copy [`.env.example`](.env.example) to `~/Library/Application Support/Wheredo/.env`.

Key settings: `STT_LANGUAGE` / `TTS_LANGUAGE`, `VISION_MODEL`, `SPEAK_FILLER`, `TTS_ENGINE` (`xai` = Grok voice, `local` = instant macOS voice). All keys are shared with the Windows/Linux app.

## Privacy

Your microphone is only recorded while you ask a question, and your screen is only captured at that moment. Both go to the xAI API and nowhere else. OAuth tokens are stored locally (`oauth.json`, chmod 600).

## License

[MIT](LICENSE)
