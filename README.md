# ABM-CLI

An interactive (and scriptable) command-line tool for managing macOS devices in **Apple Business Manager** via the [Apple Business API](https://developer.apple.com/documentation/applebusinessapi).

**Look up devices by serial, move them between MDM servers, unassign them, check Activation Lock status, and release them from your org — interactively, one-shot, or in bulk from a CSV.**

```
 █████╗ ██████╗ ███╗   ███╗   ██████╗██╗     ██╗
██╔══██╗██╔══██╗████╗ ████║  ██╔════╝██║     ██║
███████║██████╔╝██╔████╔██║  ██║     ██║     ██║
██╔══██║██╔══██║██║╚██╔╝██║  ██║     ██║     ╚═╝
██║  ██║██████╔╝██║ ╚═╝ ██║  ╚██████╗███████╗██║
╚═╝  ╚═╝╚═════╝ ╚═╝     ╚═╝   ╚═════╝╚══════╝╚═╝
```

## Features

- **Device lookup by serial** — model, product family, assignment status, current MDM server, Activation Lock status
- **Change MDM server** — interactive picker of servers integrated in your ABM (`ASSIGN_DEVICES`) (ex: jamf-prod, jamf-sandbox, fleet-prod, fleet-dev)
- **Unassign** a device from its MDM server (`UNASSIGN_DEVICES`)
- **Release** a device from the org (`RELEASE_DEVICES`) — **permanent**, guarded by a pre-release checklist
- **Pre-release checklist** — warns when Activation Lock is ON or the device is still MDM-assigned; `--yes` alone won't override it, `--force` will
- **Live activity polling** — long-running activities report *"still pending"* with a ready-to-run `status` command instead of a misleading failure
- **One-shot subcommands + batch mode** — scriptable, with `--yes` for automation
- **Audit trail** — append-only local TSV of every lookup, submission, and result (on by default)
- **CSV inventory export** — every observed device state appended as a row (optional)
- **Slack notifications** — activity results and batch summaries (optional, disabled by default)
- **Mock mode** — full flow against a fake ABM, zero credentials needed
- **Flexible secrets** — env vars, Doppler, Vault, AWS Secrets Manager, any CLI (`op`, etc.), or `config.json`

## Requirements

macOS or Linux with: `bash`, `jq`, `curl`, `openssl`, `xxd`

```sh
brew install jq   # the rest ship with macOS
```

## Quick start (no credentials)

Try the entire flow against a mock ABM Server:

```sh
./abm_tool.sh --mock
```

Mock devices: `DEMO1234XYZ` (assigned, Activation Lock ON) and `DEMO5678ABC` (unassigned). Anything else returns "not found". Mock state resets each run; set `ABM_MOCK_STATE_DIR=/some/path` to persist it across runs. **USING FLAG `--mock` WILL DO NOTHING. THIS IS FAKE DATA.**

## Setup (real ABM)

1. In [business.apple.com](https://business.apple.com), create an API key: **Preferences → API** (requires admin). You get a **client ID**, **key ID**, and a **private key (.pem)**.
2. Give the key the `business.api` scope.
3. Provide the credentials to the tool in any of these ways — first non-empty wins: **env → backend → config.json**.

### Option A: environment variables (nothing touches disk)

```sh
export ABM_CLIENT_ID="your-client-id"
export ABM_KEY_ID="your-key-id"
export ABM_PRIVATE_KEY="$(cat abm_private_key.pem)"   # or: export ABM_PEM_PATH=/secure/path/abm_private_key.pem
```

### Option B: secret backends

```sh
# Doppler (expects ABM_CLIENT_ID / ABM_KEY_ID / ABM_PRIVATE_KEY secrets)
export ABM_SECRET_BACKEND=doppler

# HashiCorp Vault KV
export ABM_SECRET_BACKEND=vault ABM_VAULT_PATH=secret/data/abm_tool

# AWS Secrets Manager (not KMS — KMS is encryption, not storage)
export ABM_SECRET_BACKEND=aws ABM_AWS_SECRET_ID=abm_tool

# Any CLI that emits the secret JSON (1Password shown)
export ABM_SECRET_CMD='op item get ABM --format json'
```

Secret JSON shape everywhere:

```json
{"client_id": "...", "key_id": "...", "private_key": "-----BEGIN PRIVATE KEY-----..."}
```

### Option C: config.json

Copy `config.example.json` to `config.json` and fill it in (`config.json` is gitignored, so real values can never be committed):

```json
{
  "client_id": "your-client-id",
  "key_id": "your-key-id",
  "pem_path": "~/scripts/abm_tool/abm_private_key.pem"
}
```

An inline `ABM_PRIVATE_KEY` is written to a `chmod 600` tempfile at runtime and cleaned up on exit — keys are never written into `config.json`.

## Usage

```sh
abm_tool.sh [--mock]               interactive session
abm_tool.sh lookup SERIAL [...]    one-shot device lookup(s)
abm_tool.sh servers                list MDM servers (ids for assign/batch)
abm_tool.sh assign SERIAL SRV_ID   move device to another MDM server
abm_tool.sh unassign SERIAL        unassign from current server
abm_tool.sh release SERIAL         release from org (permanent)
abm_tool.sh status ACTIVITY_ID     re-check a pending activity
abm_tool.sh batch FILE.csv         bulk run (see below)
abm_tool.sh --help                 full help
```

Flags (accepted anywhere on the command line):

| Flag | Effect |
|---|---|
| `--yes` / `-y` | auto-confirm prompts (does **not** override a failing pre-release checklist) |
| `--force` | proceed with release despite checklist warnings |
| `--mock` | run against the fake ABM (also `ABM_MOCK=1`) |

Without a subcommand, the tool starts an interactive REPL: enter a serial, then pick from *change MDM server / unassign / release / turn off Activation Lock / back*.

### Batch files

One device per row; `#` comments and blank lines are ignored:

```csv
# disposal run 2026-10-21
C02XYZ123,lookup
C02XYZ456,assign,SRV-JAMF-PROD
C02XYZ789,unassign
C02XYZ000,release
```

`serial` alone means `lookup`; `server_id` is only required for `assign`. Before running, the tool prints a summary (N lookups / assigns / unassigns / releases) and asks for one confirmation. Per-row failures don't abort the batch; you get an ok/failed summary at the end. Rows whose release fails the pre-release checklist are skipped unless `--force` is passed.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | success (activity COMPLETED) |
| 1 | error (not found, failed activity, cancelled, misconfiguration) |
| 2 | activity still IN_PROGRESS when the poll budget ran out (`status` only) |

## Safety notes

- **Release is permanent.** The device leaves your org, can only be re-added via Apple Configurator or an authorized reseller, and ABM stops managing its Activation Lock. Never release a device that may go to Apple for repair. Interactive releases require re-typing the serial; all releases go through the pre-release checklist.
- **Activation Lock is read-only via Apple's API.** Turning it off is web-UI-only; when a lock is detected the tool deep-links you to business.apple.com.
- The **audit trail is on by default** (`./abm_audit.log`) so releases and batch runs always leave a record. Treat it as compliance data — don't commit it.

## Integrations

All optional. Environment variables win; the parenthesized `config.json` keys are fallbacks.

### Audit trail — ON by default

```sh
ABM_AUDIT_LOG=/path/abm_audit.log   # (audit_log) default: ./abm_audit.log
ABM_AUDIT_ENABLED=0                 # to disable
```

Tab-separated: `timestamp  user  event  serial-or-activity  detail`. Events: `LOOKUP`, `SUBMIT`, `SUBMIT_FAILED`, `RESULT_<STATUS>`, `PENDING`, `RELEASE_CONFIRMED`, `ACTLOCK`, `BATCH`.

### CSV export — OFF by default

```sh
ABM_CSV_ENABLED=1                   # (csv.enabled)
ABM_CSV_PATH=/path/inventory.csv    # (csv.path) default: ./abm_inventory.csv
```

Every observed device state (lookups and the fetch before any mutation) appends one quoted row: `timestamp,serial,model,family,status,mdm_server,mdm_server_id,activation_lock`.

### Slack — OFF by default

```sh
ABM_SLACK_ENABLED=1                 # (slack.enabled)

# webhook mode (simplest — create at api.slack.com → Incoming Webhooks)
ABM_SLACK_WEBHOOK_URL=https://hooks.slack.com/services/T…/B…/…   # (slack.webhook_url)

# bot mode (chat.postMessage)
ABM_SLACK_BOT_TOKEN=xoxb-…          # (slack.bot_token)
ABM_SLACK_CHANNEL="#device-ops"     # (slack.channel)
```

Notifies on activity results (completed/failed/pending), submission failures, and batch completion. `ABM_SLACK_CLIENT_ID` / `ABM_SLACK_CLIENT_SECRET` are reserved for a future OAuth bot-install flow. Enabling Slack without configuring a mode fails fast at startup.

### Polling

```sh
ABM_POLL_MAX=40        # attempts (default ≈ 2 min budget)
ABM_POLL_INTERVAL=3    # seconds between polls
```

When the budget runs out the activity is reported as *still pending* (not failed) with a `abm_tool.sh status <id>` command to check later.

## Full config.json reference

```json
{
  "client_id": "…",
  "key_id": "…",
  "pem_path": "~/.secure/abm_private_key.pem",
  "backend": "doppler|vault|aws|cmd",
  "vault_path": "secret/data/abm_tool",
  "aws_secret_id": "abm_tool",
  "audit_log": "",
  "slack": {
    "enabled": false,
    "webhook_url": "",
    "bot_token": "",
    "channel": "",
    "client_id": "",
    "client_secret": ""
  },
  "csv": {
    "enabled": false,
    "path": ""
  }
}
```

Point at a different file with `ABM_CONFIG=/path/config.json`.

## How it works

1. Builds an ES256-signed JWT client assertion (`kid` = your key ID) using `openssl`.
2. Exchanges it at `https://account.apple.com/auth/oauth2/token` for a bearer token (`business.api` scope), cached until ~60 s before expiry.
3. Calls the Apple Business API (`https://api-business.apple.com/v1`) with automatic retry on transient failures.

## Ideas to build on

- One-shot unassign+release combo for disposal pickups
- CDW disposal-sheet formatter → batch CSV
- Slack OAuth bot install flow (client id/secret placeholders ready)

---

Not affiliated with Apple. "Apple Business Manager" and "Jamf"/"Kandji" are trademarks of their respective owners.
