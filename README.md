# AlexEstiasis

A phone-friendly **waiter ordering app built on top of an existing restaurant POS** ([Estiasis](https://www.witec.gr/) by Witec). A single self-contained **PowerShell** HTTP server runs on a machine on the restaurant LAN and serves an installable **iPhone PWA** — tables, split bills, drafts, server-side printing — plus an **AI feature that turns a free-text order note into the exact menu items**, ready to send to the kitchen.

**Demo: [watch the app in action on LinkedIn](https://www.linkedin.com/posts/alex-gkiafis_this-summer-ive-been-working-as-a-waiter-ugcPost-7476927220758822912-BtQk)**

It does **not** replace or migrate anything: it talks to the POS's own Web API, so the existing desktop system keeps working unchanged.

The app UI is **in Greek** (its users are Greek waiters); this README is in English for anyone landing on the repo from outside.

> **Why this exists.** Built while working a season at a family restaurant. The POS's mobile app only ran on Android, so the two waiters with iPhones couldn't take orders at all; the UI was clunky, and the system had quirks everyone had just learned to work around. This is the fix. Solo project.

## What it does

- **Tables & ordering** — tap a table, tap dishes from a category/product grid with accent/typo-tolerant fuzzy search, send to the kitchen.
- **AI order parsing** — a waiter writes the order in plain, messy Greek the way they'd jot it on paper (*"2 σουβλάκια χοιρινά, μια πίτα γύρο απ' όλα χωρίς κρεμμύδι, φραπέ για αρχή"*), taps a button, and the app fills in the correct products — with comments, price changes, and serving courses — applying the restaurant's **house rules**. The waiter just glances, compares, and presses OK.
- **Split bills** — split a table into named bills; move items and notes between them; print one bill or all.
- **Draft mode** — stage new items *and* edits to committed lines locally; nothing prints to the kitchen until **OK**, and cancelling reverts. Multi-device safe: drafts are shared and claimed atomically, so two phones can't double-send the same order.
- **Personal notes** — a per-table, per-bill free-text scratchpad kept entirely separate from the order (and the input to the AI feature).
- **Serving courses** — group dishes into courses the kitchen sends in order.
- **Installable PWA** — add to the home screen for a full-screen, app-like experience; comes back after a reboot via a scheduled task.

## How it works

```
┌─────────────┐     HTTP (LAN)      ┌──────────────────────┐   REST    ┌──────────────────┐
│  Waiter's   │ ─────────────────▶ │  EstiasisWeb.ps1     │ ────────▶ │  Estiasis WebApi  │
│  iPhone     │   PWA (HTML/JS)     │  (PowerShell HTTP    │           │  (IIS) + SQL +    │
│  (browser)  │ ◀───────────────── │   server / proxy)    │ ◀──────── │  IdentityServer   │
└─────────────┘                     └──────────┬───────────┘           └──────────────────┘
                                               │ HTTPS
                                               ▼
                                     ┌────────────────────┐
                                     │  Anthropic Claude   │   AI order parsing; the key stays
                                     │  API                │   server-side, never sent to the phone
                                     └────────────────────┘
```

- **Frontend** — one self-contained HTML/CSS/JS page (vanilla ES5, no build step) embedded in the PowerShell script and served to the phone.
- **Server** — the PowerShell process is a small HTTP server that proxies the Estiasis Web API (auth, tables, orders, printing, close) and adds a few endpoints of its own for drafts, notes, and AI fill.
- **AI** — the waiter's note plus the live menu and house rules go to the Claude API, which returns structured line items validated against a JSON schema. The API key never leaves the server.
- **Printing** — done by the POS itself, server-side over the LAN to the configured printers, so the app never talks to a printer directly.

## Stack

**PowerShell 5.1** (HTTP server + API proxy) · vanilla **HTML/CSS/JS** PWA (no build step) · **Estiasis Web API** (ASP.NET Core + IdentityServer4 + SQL Server) · **Anthropic Claude API** (structured output).

## Repository layout

```
EstiasisWeb.ps1               the whole app — HTTP server + embedded PWA frontend
estiasisweb_labels.json       Greek UI strings
estiasis_ai_rules.txt         AI house rules (example)
estiasis_config.example.json  template for POS endpoint + credentials
estiasis_ai_key.txt.example   template for the Anthropic key
estiasisweb-icon-*.png        home-screen icons
AlexEstiasis.png              source icon
```

## Getting started

### Prerequisites
- Windows with **PowerShell 5.1+**.
- Network access to a running **Estiasis WebApi** (IIS) on the LAN.
- An **Anthropic API key** (optional, only for the AI feature).

### 1. Configure credentials (kept out of git)
Credentials are **not** stored in the script. Either pass them as parameters, or — recommended — create a local config file next to the script:

```bash
cp estiasis_config.example.json estiasis_config.json
# edit estiasis_config.json with your WebApi URL + OAuth client header + POS login
```

For the AI feature, provide an Anthropic key one of two ways:

```bash
cp estiasis_ai_key.txt.example estiasis_ai_key.txt   # paste your key on line 1
#  — or —
setx ANTHROPIC_API_KEY "sk-ant-..."                  # use an environment variable instead
```

Both `estiasis_config.json` and `estiasis_ai_key.txt` are gitignored.

### 2. Run

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\EstiasisWeb.ps1
# or pass settings inline instead of a config file:
.\EstiasisWeb.ps1 -Port 8095 -Eb 'http://127.0.0.1/wa_estiasis' -User '...' -Pass '...' -Basic 'Basic ...'
```

### 3. Open on a phone
On a phone on the same network, browse to `http://<this-machine-LAN-ip>:8095`, then **Add to Home Screen** for the full-screen app. (iOS honours this over plain HTTP; a true standalone PWA on Android needs HTTPS.) To survive reboots, register a hidden **At-Log-On scheduled task** running the script with `-NoBrowser`, and allow the port through the firewall.

## Configuration

| What | How |
|------|-----|
| POS endpoint + credentials | `estiasis_config.json` (or `-Eb` / `-Basic` / `-User` / `-Pass` params) |
| Listening port | `-Port` (default `8095`) |
| Anthropic API key | `estiasis_ai_key.txt` or the `ANTHROPIC_API_KEY` env var |
| AI house rules | `estiasis_ai_rules.txt` (one rule per line; also editable in-app from ⚙ settings) |
| UI labels (Greek) | `estiasisweb_labels.json` |

`estiasis_ai_rules.txt` is the interesting one: plain-language rules (e.g. *"a plain «σουβλάκι» means the small one unless «μερίδα» is said"*) that the AI applies when interpreting an order. The included file is a working example.

## Built with Claude Code

The integration client, the PWA frontend, and the AI order-parsing feature were built and iterated with **Claude Code** as a pair-programmer. The trickier changes — the split-bill model, the draft/commit/cancel state machine, the staged edits to committed lines — were put through a **multi-agent adversarial review** before shipping (independent agents hunting for bugs, each finding then verified), which caught real issues like a silent note-loss path and quantity-logic edge cases. Honest framing: I drove the design and decisions; Claude did a lot of the typing and the review legwork.

## Security

- No credentials or API keys are committed; they live in gitignored files (`estiasis_config.json`, `estiasis_ai_key.txt`) or in environment variables / parameters.
- The Anthropic API key is used **server-side only** and is never sent to the browser.
- The app is meant for a **trusted private LAN** and has no auth of its own — anyone who can reach the port can use it. Don't expose it to the public internet; use a VPN for remote access, and prefer HTTPS with a trusted certificate if you serve it beyond localhost.

## Disclaimer

This is an independent, unofficial companion UI that integrates with the **Estiasis** POS by Witec via its existing API. It is **not affiliated with or endorsed by Witec**, and it contains none of the vendor's proprietary code, schema, or binaries — only the integration client. Use it only against a system you are authorized to use. Provided as-is, for educational and personal use.

## License

[MIT](LICENSE) — applies to my own code in this repo. It integrates with the proprietary Estiasis POS, which is not included and retains its original copyright.
