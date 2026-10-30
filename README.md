# Usher

A macOS menu bar app that gives the window you're working in the right amount of screen, automatically.

When focus changes, Usher asks an LLM (Jev, via [OpenRouter](https://openrouter.ai)) what kind of work the window is, then sizes it to match and arranges your other windows around it:

| Category | Examples | Default share |
|---|---|---|
| Code | editors, IDEs, terminals | two-thirds |
| Reference | docs, articles | half |
| Media | video, presentations | full |
| Chat | messaging, email | one-third |
| Writing | notes, documents | half |
| Ambient | music, monitors, settings | one-third |

Shares can be changed from the menu bar under **Sizes**.

The other windows go into columns or a grid sized to stay usable, not thin strips. On an ultrawide display, a half or one-third window sits in the center with windows on both sides. If there isn't room for a usable side window (on a laptop screen, for example), Usher leaves it where it is.

Answers are cached per app and window title, so switching back to a window is instant. If the request fails or there's no API key, Usher falls back to a built-in guess based on the app.

## Setup

Requires macOS 13 or later and Swift 5.10 or later (Xcode or the Command Line Tools).

1. Add your OpenRouter API key, either as an environment variable:

   ```sh
   export OPENROUTER_API_KEY=sk-or-...
   ```

   or in a file:

   ```sh
   mkdir -p ~/.config/usher && chmod 700 ~/.config/usher
   # paste the key into ~/.config/usher/openrouter_key
   chmod 600 ~/.config/usher/openrouter_key
   ```

2. Build and run:

   ```sh
   swift build
   .build/debug/Usher
   ```

3. Grant Accessibility permission when prompted: **System Settings > Privacy & Security > Accessibility**, then turn on the app that launched Usher (your terminal). Usher waits and starts tiling as soon as permission is granted.

## Testing without moving windows

```sh
# Ask Jev to classify a window
.build/debug/Usher --classify com.google.Chrome "YouTube - Some video"

# Print the layout for a screen size, share and number of side windows
.build/debug/Usher --plan 3440 1440 half 3
```

## Options

- `USHER_EFFORT=default` lets the router pick its own reasoning effort. By default Usher asks for low effort.

## License

MIT
