# Usher

**Usher gives the window you're working in the right amount of screen, automatically.**

Usher is a macOS menu bar app. When you switch windows, it works out what kind of work the window is for, then resizes it and arranges your other windows around it.

---

## How it works

1. You focus a window.
2. Usher sends the app's name and the window title to an LLM ([Jev](https://openrouter.ai/typesafe/jev-router) on OpenRouter), which sorts the window into a category.
3. The window gets that category's share of the screen. Your other windows fill the rest.

| Category | For | Share |
|---|---|---|
| Code | editors, IDEs, terminals | ⅔ |
| Reference | docs, articles | ½ |
| Media | video, presentations | full |
| Writing | notes, documents | ½ |
| Chat | messaging, email | ⅓ |
| Ambient | music, monitors, settings | ⅓ |

Change any of these from the menu bar under **Sizes**.

**Details**
- **No thin strips:** side windows go into columns or a grid sized to stay usable.
- **Ultrawide aware:** a window with a half or one-third share sits in the center, with other windows on both sides.
- **Instant on repeat:** answers are cached per app and title, so switching back to a window doesn't call the LLM again.
- **Works offline:** with no network or no API key, Usher guesses the category from the app.

## It learns

- **From your resizes.** If you resize a window Usher placed, Usher remembers the size you picked for that app and that kind of work. Resize Chrome on docs to two-thirds and Chrome on docs opens at two-thirds from then on, while Chrome on YouTube still goes full screen. See or forget these under **Learned Sizes**.
- **From your rules.** Open the menu while an app is focused to set a rule for that app: **Always Full**, **Always Half**, and so on, or **Never Tile**. Apps with a rule skip the LLM entirely.

Usher picks a share in this order: app rule, then learned size, then category default.

## Install

Requires macOS 13 or later and Swift 5.10 or later.

```sh
git clone https://github.com/jabreeflor/usher.git
cd usher
swift build
```

## Setup

**1. Add an [OpenRouter](https://openrouter.ai/keys) API key.** Set an environment variable:

```sh
export OPENROUTER_API_KEY=sk-or-...
```

Or save the key to a file:

```sh
mkdir -p ~/.config/usher && chmod 700 ~/.config/usher
pbpaste > ~/.config/usher/openrouter_key   # copy the key first
chmod 600 ~/.config/usher/openrouter_key
```

**2. Run Usher.**

```sh
.build/debug/Usher
```

**3. Grant Accessibility permission.** Open **System Settings → Privacy & Security → Accessibility** and turn on the app that launched Usher, which is usually your terminal. Usher starts tiling as soon as it has access.

## Try it without moving windows

```sh
# Classify a window
.build/debug/Usher --classify com.google.Chrome "YouTube - Some video"

# Preview a layout: width, height, share, number of side windows
.build/debug/Usher --plan 3440 1440 half 3
```

## Configuration

| Variable | Default | What it does |
|---|---|---|
| `OPENROUTER_API_KEY` | none | API key. Overrides the key file. |
| `USHER_EFFORT` | `low` | Reasoning effort sent to the model. Set it to `default` to let the router decide. |

## License

[MIT](LICENSE)
