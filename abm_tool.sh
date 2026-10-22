#!/usr/bin/env bash
# ABM-CLI — Apple Business Manager device tool.
# interactive REPL + one-shot subcommands: lookup / servers / assign / unassign /
# release / status / batch (see --help).
# Secrets: env vars → backend (doppler|vault|aws|cmd) → config.json.
# Integrations: audit trail on by default; Slack notify + CSV export off unless enabled.
# Demo without creds: ./abm_tool.sh --mock   (or ABM_MOCK=1)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="${ABM_CONFIG:-$SCRIPT_DIR/config.json}"
TOKEN_URL="https://account.apple.com/auth/oauth2/token"
API_BASE="https://api-business.apple.com/v1"

MOCK="${ABM_MOCK:-0}"
[ "${1:-}" = "--mock" ] && { MOCK=1; shift; }
YES=0; FORCE=0   # --yes auto-confirms prompts; --force overrides the pre-release checklist

# ---------- colors (off when piped / NO_COLOR; CLICOLOR_FORCE overrides) ----------
if { [ -t 1 ] || [ -n "${CLICOLOR_FORCE:-}" ]; } && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m';  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m';   C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m';  C_CYAN=$'\033[36m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""
fi

ACCESS_TOKEN=""
TOKEN_EXP=0
MOCK_STATE_DIR=""
PEM_TMP=""

die() { echo "${C_RED}ERROR:${C_RESET} $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required (brew install $1)"; }
MOCK_STATE_OWNED=""   # only rm a state dir we created (not ABM_MOCK_STATE_DIR)

cleanup() {
    [ -n "$MOCK_STATE_OWNED" ] && rm -rf "$MOCK_STATE_OWNED"
    [ -n "$PEM_TMP" ] && rm -f "$PEM_TMP"
    return 0
}
trap cleanup EXIT

# ---------- help / banner ----------
show_help() {
    local L1=' █████╗ ██████╗ ███╗   ███╗' L2='██╔══██╗██╔══██╗████╗ ████║'
    local L3='███████║██████╔╝██╔████╔██║' L4='██╔══██║██╔══██║██║╚██╔╝██║'
    local L5='██║  ██║██████╔╝██║ ╚═╝ ██║' L6='╚═╝  ╚═╝╚═════╝ ╚═╝     ╚═╝'
    local R1='   ██████╗██╗     ██╗' R2='  ██╔════╝██║     ██║'
    local R3='  ██║     ██║     ██║' R4='  ██║     ██║     ╚═╝'
    local R5='  ╚██████╗███████╗██╗' R6='   ╚═════╝╚══════╝╚═╝'
    echo ""
    echo "${C_RED}${C_BOLD}${L1}${C_RESET}${C_BLUE}${C_BOLD}${R1}${C_RESET}"
    echo "${C_RED}${C_BOLD}${L2}${C_RESET}${C_BLUE}${C_BOLD}${R2}${C_RESET}"
    echo "${C_RED}${C_BOLD}${L3}${C_RESET}${C_BLUE}${C_BOLD}${R3}${C_RESET}"
    echo "${C_RED}${C_BOLD}${L4}${C_RESET}${C_BLUE}${C_BOLD}${R4}${C_RESET}"
    echo "${C_RED}${C_BOLD}${L5}${C_RESET}${C_BLUE}${C_BOLD}${R5}${C_RESET}"
    echo "${C_RED}${C_BOLD}${L6}${C_RESET}${C_BLUE}${C_BOLD}${R6}${C_RESET}"
    echo ""
    echo "  ${C_BOLD}Apple Business Manager — device lifecycle CLI${C_RESET}"
    echo "  ${C_DIM}docs: https://developer.apple.com/documentation/applebusinessapi${C_RESET}"
    echo ""
    echo "${C_BOLD}USAGE${C_RESET}"
    echo "  abm_tool.sh [--mock]               interactive session"
    echo "  abm_tool.sh lookup SERIAL [...]    one-shot device lookup(s)"
    echo "  abm_tool.sh servers                list MDM servers (ids for assign/batch)"
    echo "  abm_tool.sh assign SERIAL SRV_ID   move device to another MDM server"
    echo "  abm_tool.sh unassign SERIAL        unassign from current server"
    echo "  abm_tool.sh release SERIAL         release from org (permanent)"
    echo "  abm_tool.sh status ACTIVITY_ID     re-check a pending activity"
    echo "  abm_tool.sh batch FILE.csv         bulk run (see BATCH FILE)"
    echo "  flags: --yes auto-confirm · --force override a failing pre-release checklist · --mock / ABM_MOCK=1"
    echo ""
    echo "${C_BOLD}BATCH FILE${C_RESET} ${C_DIM}(one device per row; '#' comments and blanks ignored)${C_RESET}"
    echo "  ${C_DIM}serial,action,server_id${C_RESET}   action = lookup|assign|unassign|release"
    echo "  ${C_DIM}serial${C_RESET} alone = lookup; server_id only needed for assign"
    echo ""
    echo "${C_BOLD}SUPPORTS TODAY${C_RESET}"
    echo "  ${C_CYAN}●${C_RESET} device lookup by serial — model, assignment status, current MDM server"
    echo "  ${C_CYAN}●${C_RESET} Activation Lock status on lookup ${C_DIM}(read-only API — turning it off is web-UI-only;"
    echo "    the tool deep-links you to business.apple.com when a lock is detected)${C_RESET}"
    echo "  ${C_CYAN}●${C_RESET} change MDM server — pick from servers integrated in your ABM ${C_DIM}(ASSIGN_DEVICES)${C_RESET}"
    echo "  ${C_CYAN}●${C_RESET} unassign device from its MDM server ${C_DIM}(UNASSIGN_DEVICES)${C_RESET}"
    echo "  ${C_CYAN}●${C_RESET} release device from the org — permanent, re-type serial to confirm ${C_DIM}(RELEASE_DEVICES)${C_RESET}"
    echo "  ${C_CYAN}●${C_RESET} live activity polling — long activities report 'still pending' with a status command"
    echo "  ${C_CYAN}●${C_RESET} mock mode — full flow against a fake ABM, zero creds needed"
    echo "    ${C_DIM}(state resets per run; ABM_MOCK_STATE_DIR=/path makes it persist across runs)${C_RESET}"
    echo ""
    echo "${C_BOLD}SECRETS${C_RESET} ${C_DIM}(first non-empty wins: env → backend → config.json)${C_RESET}"
    echo "  ${C_CYAN}env session:${C_RESET} nothing touches disk —"
    echo "    export ABM_CLIENT_ID=... ABM_KEY_ID=..."
    echo "    export ABM_PRIVATE_KEY=\"\$(cat key.pem)\"   ${C_DIM}# or ABM_PEM_PATH=/secure/key.pem${C_RESET}"
    echo "  ${C_CYAN}backends:${C_RESET}  ABM_SECRET_BACKEND=doppler   ${C_DIM}# ABM_CLIENT_ID/ABM_KEY_ID/ABM_PRIVATE_KEY in Doppler${C_RESET}"
    echo "            ABM_SECRET_BACKEND=vault ABM_VAULT_PATH=secret/data/abm_tool"
    echo "            ABM_SECRET_BACKEND=aws   ABM_AWS_SECRET_ID=abm_tool ${C_DIM}# Secrets Manager, not KMS${C_RESET}"
    echo "            ABM_SECRET_CMD='op item get ABM --format json'  ${C_DIM}# any CLI, emits secret JSON${C_RESET}"
    echo "  ${C_CYAN}file:${C_RESET}      config.json next to this script ${C_DIM}{\"client_id\",\"key_id\",\"pem_path\"}${C_RESET}"
    echo "  secret JSON shape everywhere: ${C_DIM}{\"client_id\":\"...\",\"key_id\":\"...\",\"private_key\":\"-----BEGIN...\"}${C_RESET}"
    echo "  ${C_DIM}note: AWS KMS is encryption, not secret storage — use Secrets Manager,${C_RESET}"
    echo "  ${C_DIM}or wrap KMS-encrypted blobs via ABM_SECRET_CMD. Inline keys go to a 600 tempfile, never config.json.${C_RESET}"
    echo ""
    echo "${C_BOLD}INTEGRATIONS${C_RESET} ${C_DIM}(env wins; config.json key shown in parens)${C_RESET}"
    echo "  ${C_CYAN}audit trail${C_RESET} — ON by default; append-only TSV of lookups, submissions, results:"
    echo "    ABM_AUDIT_LOG=path (audit_log) ${C_DIM}default: ./abm_audit.log${C_RESET} · ABM_AUDIT_ENABLED=0 to disable"
    echo "  ${C_CYAN}csv export${C_RESET} — OFF by default; every observed device state appends a row:"
    echo "    ABM_CSV_ENABLED=1 (csv.enabled) · ABM_CSV_PATH=path (csv.path) ${C_DIM}default: ./abm_inventory.csv${C_RESET}"
    echo "  ${C_CYAN}slack${C_RESET} — OFF by default; notifies on activity results and batch completion:"
    echo "    ABM_SLACK_ENABLED=1 (slack.enabled), then one of:"
    echo "    webhook: ABM_SLACK_WEBHOOK_URL=https://hooks.slack.com/services/… (slack.webhook_url)"
    echo "    bot:     ABM_SLACK_BOT_TOKEN=xoxb-… + ABM_SLACK_CHANNEL=#channel (slack.bot_token / slack.channel)"
    echo "    ${C_DIM}ABM_SLACK_CLIENT_ID / ABM_SLACK_CLIENT_SECRET reserved for a future OAuth bot install${C_RESET}"
    echo "  ${C_CYAN}polling${C_RESET}  ABM_POLL_MAX=40 ABM_POLL_INTERVAL=3 ${C_DIM}(≈2 min budget before 'still pending')${C_RESET}"
    echo ""
    echo "${C_BOLD}IDEAS TO BUILD ON${C_RESET}"
    echo "  ${C_YELLOW}◦${C_RESET} one-shot unassign+release combo for disposal pickups"
    echo "  ${C_YELLOW}◦${C_RESET} CDW disposal-sheet formatter → batch csv"
    echo "  ${C_YELLOW}◦${C_RESET} Slack OAuth bot install flow (client id/secret placeholders ready)"
    echo ""
}

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# ES256 sign: openssl emits DER; JWT needs raw r||s (32 bytes each)
es256_sign() {
    local pem="$1" der r s
    der=$(mktemp -t abm_sig)
    openssl dgst -sha256 -sign "$pem" -out "$der"
    r=$(openssl asn1parse -inform DER -in "$der" | awk -F: '/INTEGER/{print $NF}' | sed -n '1p')
    s=$(openssl asn1parse -inform DER -in "$der" | awk -F: '/INTEGER/{print $NF}' | sed -n '2p')
    rm -f "$der"
    r=${r: -64}; s=${s: -64}
    { printf '%064s' "$r"; printf '%064s' "$s"; } | tr ' ' 0 | xxd -r -p
}

# ---------- secret backends ----------
BACKEND="${ABM_SECRET_BACKEND:-}"
VAULT_PATH="${ABM_VAULT_PATH:-secret/data/abm_tool}"
AWS_SECRET_ID="${ABM_AWS_SECRET_ID:-abm_tool}"
SECRET_CMD="${ABM_SECRET_CMD:-}"

# ---------- integrations (optional; env vars win, config.json is fallback) ----------
# Slack: disabled by default. Webhook mode needs only ABM_SLACK_WEBHOOK_URL.
# Bot mode needs ABM_SLACK_BOT_TOKEN (xoxb-…) + ABM_SLACK_CHANNEL.
# ABM_SLACK_CLIENT_ID / ABM_SLACK_CLIENT_SECRET are placeholders for a future
# OAuth bot-install flow — not used yet.
SLACK_ENABLED="${ABM_SLACK_ENABLED:-0}"
SLACK_WEBHOOK_URL="${ABM_SLACK_WEBHOOK_URL:-}"
SLACK_BOT_TOKEN="${ABM_SLACK_BOT_TOKEN:-}"
SLACK_CHANNEL="${ABM_SLACK_CHANNEL:-}"
SLACK_CLIENT_ID="${ABM_SLACK_CLIENT_ID:-}"
SLACK_CLIENT_SECRET="${ABM_SLACK_CLIENT_SECRET:-}"
# CSV inventory export: disabled by default; every observed device state appends one row.
CSV_ENABLED="${ABM_CSV_ENABLED:-0}"
CSV_PATH="${ABM_CSV_PATH:-$SCRIPT_DIR/abm_inventory.csv}"
# Audit trail: ON by default (append-only TSV).
AUDIT_ENABLED="${ABM_AUDIT_ENABLED:-1}"
AUDIT_LOG="${ABM_AUDIT_LOG:-$SCRIPT_DIR/abm_audit.log}"
# Activity polling budget before reporting "still pending" (default ≈ 2 min).
POLL_MAX="${ABM_POLL_MAX:-40}"
POLL_INTERVAL="${ABM_POLL_INTERVAL:-3}"

slack_notify() { # text — no-op unless SLACK_ENABLED=1; never fails the script
    [ "$SLACK_ENABLED" = "1" ] || return 0
    if [ -n "$SLACK_WEBHOOK_URL" ]; then
        curl -sS -m 10 -X POST -H 'Content-type: application/json' \
            -d "$(jq -n --arg t "$1" '{text:$t}')" "$SLACK_WEBHOOK_URL" >/dev/null 2>&1 || true
    elif [ -n "$SLACK_BOT_TOKEN" ] && [ -n "$SLACK_CHANNEL" ]; then
        curl -sS -m 10 -X POST "https://slack.com/api/chat.postMessage" \
            -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
            -H 'Content-type: application/json' \
            -d "$(jq -n --arg c "$SLACK_CHANNEL" --arg t "$1" '{channel:$c,text:$t}')" >/dev/null 2>&1 || true
    fi
    return 0
}

audit() { # event serial detail — append-only local trail; disables itself if unwritable
    [ "$AUDIT_ENABLED" = "1" ] || return 0
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${USER:-unknown}" "$1" "$2" "$3" >> "$AUDIT_LOG" 2>/dev/null \
        || { echo "${C_YELLOW}⚠ audit log not writable ($AUDIT_LOG) — disabling${C_RESET}" >&2; AUDIT_ENABLED=0; }
    return 0
}

csv_escape() { local s="${1//\"/\"\"}"; printf '"%s"' "$s"; }

csv_row() { # serial — appends DEVICE_* globals from fetch_device as one CSV row
    [ "$CSV_ENABLED" = "1" ] || return 0
    if [ ! -s "$CSV_PATH" ]; then
        echo 'timestamp,serial,model,family,status,mdm_server,mdm_server_id,activation_lock' > "$CSV_PATH" || return 1
    fi
    {
        printf '%s,' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        csv_escape "$1";                                  printf ','
        csv_escape "$DEVICE_MODEL";                       printf ','
        csv_escape "$DEVICE_FAMILY";                      printf ','
        csv_escape "$DEVICE_STATUS";                      printf ','
        csv_escape "$DEVICE_SERVER_NAME";                 printf ','
        csv_escape "$DEVICE_SERVER_ID";                   printf ','
        if [ "$DEVICE_ALOCK" = "ON" ]; then
            csv_escape "ON (${DEVICE_ALOCK_TYPE})"
        else
            csv_escape "$DEVICE_ALOCK"
        fi
        printf '\n'
    } >> "$CSV_PATH"
}

load_integrations() { # config.json fallbacks for anything env didn't set
    [ -f "$CONFIG_PATH" ] || return 0
    local v
    v=$(jq -r '.slack.enabled // empty' "$CONFIG_PATH")
    { [ "$v" = "true" ] || [ "$v" = "1" ]; } && [ "$SLACK_ENABLED" != "1" ] && SLACK_ENABLED=1
    [ -z "$SLACK_WEBHOOK_URL" ]   && SLACK_WEBHOOK_URL=$(jq -r '.slack.webhook_url // empty' "$CONFIG_PATH")
    [ -z "$SLACK_BOT_TOKEN" ]     && SLACK_BOT_TOKEN=$(jq -r '.slack.bot_token // empty' "$CONFIG_PATH")
    [ -z "$SLACK_CHANNEL" ]       && SLACK_CHANNEL=$(jq -r '.slack.channel // empty' "$CONFIG_PATH")
    [ -z "$SLACK_CLIENT_ID" ]     && SLACK_CLIENT_ID=$(jq -r '.slack.client_id // empty' "$CONFIG_PATH")
    [ -z "$SLACK_CLIENT_SECRET" ] && SLACK_CLIENT_SECRET=$(jq -r '.slack.client_secret // empty' "$CONFIG_PATH")
    v=$(jq -r '.csv.enabled // empty' "$CONFIG_PATH")
    { [ "$v" = "true" ] || [ "$v" = "1" ]; } && [ "$CSV_ENABLED" != "1" ] && CSV_ENABLED=1
    [ -z "${ABM_CSV_PATH:-}" ] && { v=$(jq -r '.csv.path // empty' "$CONFIG_PATH"); [ -n "$v" ] && CSV_PATH="$v"; }
    [ -z "${ABM_AUDIT_LOG:-}" ] && { v=$(jq -r '.audit_log // empty' "$CONFIG_PATH"); [ -n "$v" ] && AUDIT_LOG="$v"; }
    return 0
}

validate_integrations() { # fail fast on misconfiguration before doing any work
    if [ "$SLACK_ENABLED" = "1" ]; then
        if [ -z "$SLACK_WEBHOOK_URL" ] && { [ -z "$SLACK_BOT_TOKEN" ] || [ -z "$SLACK_CHANNEL" ]; }; then
            die "slack enabled but unconfigured — set ABM_SLACK_WEBHOOK_URL, or ABM_SLACK_BOT_TOKEN + ABM_SLACK_CHANNEL"
        fi
        echo "${C_DIM}slack: notifications enabled${C_RESET}"
    fi
    if [ "$CSV_ENABLED" = "1" ]; then
        { [ -e "$CSV_PATH" ] && [ -w "$CSV_PATH" ]; } \
            || { [ ! -e "$CSV_PATH" ] && [ -w "$(dirname "$CSV_PATH")" ]; } \
            || die "CSV path not writable: $CSV_PATH"
        echo "${C_DIM}csv: appending lookups to $CSV_PATH${C_RESET}"
    fi
    if [ "$AUDIT_ENABLED" = "1" ]; then
        if { [ -e "$AUDIT_LOG" ] && [ ! -w "$AUDIT_LOG" ]; } \
            || { [ ! -e "$AUDIT_LOG" ] && [ ! -w "$(dirname "$AUDIT_LOG")" ]; }; then
            echo "${C_YELLOW}⚠ audit log not writable ($AUDIT_LOG) — audit disabled${C_RESET}"
            AUDIT_ENABLED=0
        fi
    fi
    return 0
}

fetch_backend() { # -> {"client_id","key_id","private_key"} on stdout
    case "$BACKEND" in
        doppler)
            need doppler
            jq -n --arg c "$(doppler secrets get ABM_CLIENT_ID --plain)" \
                  --arg k "$(doppler secrets get ABM_KEY_ID --plain)" \
                  --arg p "$(doppler secrets get ABM_PRIVATE_KEY --plain)" \
                  '{client_id:$c,key_id:$k,private_key:$p}'
            ;;
        vault)
            need vault
            vault kv get -format=json "$VAULT_PATH" \
                | jq '(.data.data // .data) | {client_id, key_id, private_key}'
            ;;
        aws)
            need aws
            aws secretsmanager get-secret-value --secret-id "$AWS_SECRET_ID" \
                --query SecretString --output text
            ;;
        cmd)
            [ -n "$SECRET_CMD" ] || die "ABM_SECRET_BACKEND=cmd but ABM_SECRET_CMD is empty"
            sh -c "$SECRET_CMD"
            ;;
        *) die "unknown ABM_SECRET_BACKEND '$BACKEND' (want: doppler|vault|aws|cmd)" ;;
    esac
}

load_config() {
    CLIENT_ID="${ABM_CLIENT_ID:-}"
    KEY_ID="${ABM_KEY_ID:-}"
    PEM_PATH="${ABM_PEM_PATH:-}"
    PRIVATE_KEY="${ABM_PRIVATE_KEY:-}"

    # config.json may also point at a backend
    if [ -f "$CONFIG_PATH" ] && [ -z "$BACKEND" ]; then
        BACKEND=$(jq -r '.backend // empty' "$CONFIG_PATH")
        [ -z "${ABM_VAULT_PATH:-}" ] && VAULT_PATH=$(jq -r '.vault_path // empty' "$CONFIG_PATH" || true)
        [ -z "$VAULT_PATH" ] && VAULT_PATH="secret/data/abm_tool"
        [ -z "${ABM_AWS_SECRET_ID:-}" ] && AWS_SECRET_ID=$(jq -r '.aws_secret_id // empty' "$CONFIG_PATH" || true)
        [ -z "$AWS_SECRET_ID" ] && AWS_SECRET_ID="abm_tool"
    fi

    local incomplete=0
    { [ -z "$CLIENT_ID" ] || [ -z "$KEY_ID" ] || { [ -z "$PEM_PATH" ] && [ -z "$PRIVATE_KEY" ]; }; } && incomplete=1

    if [ "$incomplete" = 1 ] && [ -n "$BACKEND" ]; then
        local fetched
        fetched=$(fetch_backend) || die "secret fetch via '$BACKEND' failed"
        [ -z "$CLIENT_ID" ]   && CLIENT_ID=$(echo "$fetched" | jq -r '.client_id // empty')
        [ -z "$KEY_ID" ]      && KEY_ID=$(echo "$fetched" | jq -r '.key_id // empty')
        [ -z "$PRIVATE_KEY" ] && PRIVATE_KEY=$(echo "$fetched" | jq -r '.private_key // empty')
        [ -z "$PEM_PATH" ]    && PEM_PATH=$(echo "$fetched" | jq -r '.pem_path // empty')
    fi

    # config.json fills any remaining gaps (placeholders count as empty)
    if [ -f "$CONFIG_PATH" ]; then
        local v
        [ -z "$CLIENT_ID" ] && { v=$(jq -r '.client_id // empty' "$CONFIG_PATH"); [ "$v" != "PASTE_CLIENT_ID_HERE" ] && CLIENT_ID="$v"; }
        [ -z "$KEY_ID" ]    && { v=$(jq -r '.key_id // empty' "$CONFIG_PATH");    [ "$v" != "PASTE_KEY_ID_HERE" ]    && KEY_ID="$v"; }
        [ -z "$PEM_PATH" ]  && PEM_PATH=$(jq -r '.pem_path // empty' "$CONFIG_PATH")
    fi

    [ -n "$CLIENT_ID" ] || die "no client_id — set ABM_CLIENT_ID, a backend, or $CONFIG_PATH (see --help)"
    [ -n "$KEY_ID" ]    || die "no key_id — set ABM_KEY_ID, a backend, or $CONFIG_PATH"

    PEM_PATH="${PEM_PATH/#\~/$HOME}"
    if [ -z "$PEM_PATH" ] && [ -n "$PRIVATE_KEY" ]; then
        PEM_TMP=$(mktemp -t abm_key); chmod 600 "$PEM_TMP"
        printf '%s\n' "$PRIVATE_KEY" > "$PEM_TMP"
        PEM_PATH="$PEM_TMP"
    fi
    [ -n "$PEM_PATH" ] && [ -f "$PEM_PATH" ] || die "private key missing — ABM_PRIVATE_KEY, ABM_PEM_PATH, backend, or pem_path in $CONFIG_PATH"

    local src="config.json"
    [ -n "${ABM_CLIENT_ID:-}" ] && src="env"
    [ -n "$BACKEND" ] && [ "$src" != "env" ] && src="backend:$BACKEND"
    echo "${C_DIM}credentials: client_id=${CLIENT_ID:0:8}… via $src${C_RESET}"
}

get_token() {
    if [ "$MOCK" = "1" ]; then
        ACCESS_TOKEN="mock-token"; TOKEN_EXP=9999999999
        echo "${C_YELLOW}⚡ MOCK MODE${C_RESET} — no network calls"
        return
    fi
    local now header payload signed assertion resp
    now=$(date +%s)
    header=$(printf '{"alg":"ES256","kid":"%s","typ":"JWT"}' "$KEY_ID" | b64url)
    payload=$(printf '{"iss":"%s","sub":"%s","aud":"%s","iat":%d,"exp":%d,"jti":"%s"}' \
        "$CLIENT_ID" "$CLIENT_ID" "$TOKEN_URL" "$now" "$((now + 600))" "$(uuidgen)" | b64url)
    signed=$(printf '%s.%s' "$header" "$payload" | es256_sign "$PEM_PATH" | b64url)
    assertion="${header}.${payload}.${signed}"
    resp=$(curl -sS -X POST "$TOKEN_URL" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=client_credentials" \
        -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
        --data-urlencode "client_assertion=${assertion}" \
        -d "scope=business.api")
    ACCESS_TOKEN=$(echo "$resp" | jq -r '.access_token // empty')
    [ -n "$ACCESS_TOKEN" ] || die "token exchange failed: $resp"
    TOKEN_EXP=$(( $(date +%s) + $(echo "$resp" | jq -r '.expires_in // 3600') - 60 ))
    echo "${C_GREEN}✔ authenticated${C_RESET} ${C_DIM}(token expires in $(echo "$resp" | jq -r '.expires_in // 3600')s)${C_RESET}"
}

# ---------------- mock ABM backend ----------------
mock_server_name() {
    case "$1" in
        SRV-JAMF-PROD)    echo "Jamf Pro (Production)" ;;
        SRV-JAMF-SANDBOX) echo "Jamf Pro (Sandbox)" ;;
        SRV-KANDJI)       echo "Kandji" ;;
        *)                echo "?" ;;
    esac
}

mock_api() {
    local method="$1" path="$2"; shift 2
    case "$method $path" in
        "GET /mdmServers"*)
            jq -n '{data:[
              {id:"SRV-JAMF-PROD",type:"mdmServers",attributes:{serverName:"Jamf Pro (Production)"}},
              {id:"SRV-JAMF-SANDBOX",type:"mdmServers",attributes:{serverName:"Jamf Pro (Sandbox)"}},
              {id:"SRV-KANDJI",type:"mdmServers",attributes:{serverName:"Kandji"}}]}'
            ;;
        "GET /orgDevices/"*/assignedServer)
            local serial sfile sid
            serial=$(echo "$path" | cut -d/ -f3)
            sfile="$MOCK_STATE_DIR/$serial.server"
            [ -f "$sfile" ] || { echo "API_404: device is not assigned to a server"; return 1; }
            sid=$(cat "$sfile")
            jq -n --arg id "$sid" --arg name "$(mock_server_name "$sid")" \
                '{data:{id:$id,type:"mdmServers",attributes:{serverName:$name}}}'
            ;;
        "GET /orgDevices/"*/activationLockStatus)
            local serial afile
            serial=$(echo "$path" | cut -d/ -f3)
            afile="$MOCK_STATE_DIR/$serial.alock"
            if [ -f "$afile" ]; then
                jq -n --arg id "$serial" --arg lt "$(cat "$afile")" \
                    '{data:{type:"activationLockStatus",id:$id,attributes:{isLocked:true,lockType:$lt}}}'
            else
                jq -n --arg id "$serial" \
                    '{data:{type:"activationLockStatus",id:$id,attributes:{isLocked:false,lockType:null}}}'
            fi
            ;;
        "GET /orgDevices/"*)
            local serial model family status released_at=""
            serial="${path##*/}"
            case "$serial" in
                DEMO1234XYZ) model="MacBook Pro (16-inch, 2021)"; family="Mac" ;;
                DEMO5678ABC) model="MacBook Air (15-inch, M2, 2023)"; family="Mac" ;;
                *) echo "API_404: no such device"; return 1 ;;
            esac
            if [ -f "$MOCK_STATE_DIR/$serial.released" ]; then
                status="RELEASED"; released_at=$(cat "$MOCK_STATE_DIR/$serial.released")
            elif [ -f "$MOCK_STATE_DIR/$serial.server" ]; then
                status="ASSIGNED"
            else
                status="UNASSIGNED"
            fi
            jq -n --arg id "$serial" --arg sn "$serial" --arg model "$model" \
                  --arg fam "$family" --arg st "$status" --arg rel "$released_at" \
                '{data:{id:$id,type:"orgDevices",attributes:{
                    serialNumber:$sn,deviceModel:$model,productFamily:$fam,
                    productType:"Mac",status:$st,
                    releasedFromOrgDateTime:(if $rel=="" then null else $rel end)}}}'
            ;;
        "POST /orgDeviceActivities")
            local body atype serial server id
            body=$(cat)
            atype=$(echo "$body" | jq -r '.data.attributes.activityType')
            serial=$(echo "$body" | jq -r '.data.relationships.devices.data[0].id')
            server=$(echo "$body" | jq -r '.data.relationships.mdmServer.data.id // empty')
            case "$atype" in
                ASSIGN_DEVICES)   echo "$server" > "$MOCK_STATE_DIR/$serial.server" ;;
                UNASSIGN_DEVICES) rm -f "$MOCK_STATE_DIR/$serial.server" ;;
                RELEASE_DEVICES)  rm -f "$MOCK_STATE_DIR/$serial.server" "$MOCK_STATE_DIR/$serial.alock"
                                  date -u +%Y-%m-%dT%H:%M:%SZ > "$MOCK_STATE_DIR/$serial.released" ;;
            esac
            id=$(uuidgen | tr '[:upper:]' '[:lower:]')
            jq -n --arg id "$id" --arg self "/orgDeviceActivities/$id" \
                '{data:{type:"orgDeviceActivities",id:$id,
                        attributes:{status:"IN_PROGRESS",subStatus:"SUBMITTED"},
                        links:{self:$self}}}'
            ;;
        "GET /orgDeviceActivities/"*)
            jq -n '{data:{attributes:{status:"COMPLETED",subStatus:"COMPLETED",
                        createdDateTime:"2026-10-09T12:00:00Z"}}}'
            ;;
        *) echo "API_404: mock has no route for $method $path"; return 1 ;;
    esac
}
# ---------------- end mock backend ----------------

# api METHOD PATH [curl extra args...] -> body on stdout; fails on HTTP error
api() {
    local method="$1" path="$2"; shift 2
    [ "$MOCK" = "1" ] && { mock_api "$method" "$path" "$@"; return; }
    if [ "$(date +%s)" -ge "$TOKEN_EXP" ]; then get_token >/dev/null; fi
    local body code
    body=$(mktemp -t abm_body)
    code=$(curl -sS -o "$body" -w '%{http_code}' -X "$method" "${API_BASE}${path}" \
        --retry 3 --retry-all-errors --retry-delay 1 --connect-timeout 10 --max-time 60 \
        -H "Authorization: Bearer ${ACCESS_TOKEN}" -H "Content-Type: application/json" "$@")
    if [ "$code" -ge 400 ]; then
        local msg; msg=$(cat "$body"); rm -f "$body"
        echo "API_${code}: ${msg}"
        return 1
    fi
    cat "$body"; rm -f "$body"
}

# ---------- pretty printing ----------
color_status() {
    case "$1" in
        COMPLETED)              echo "${C_GREEN}$1${C_RESET}" ;;
        ASSIGNED)               echo "${C_CYAN}$1${C_RESET}" ;;
        UNASSIGNED|IN_PROGRESS) echo "${C_YELLOW}$1${C_RESET}" ;;
        RELEASED|FAILED)        echo "${C_RED}$1${C_RESET}" ;;
        *)                      echo "$1" ;;
    esac
}

list_servers() {
    api GET "/mdmServers?limit=200" | jq -r '.data[] | "\(.id)\t\(.attributes.serverName // "?")"'
}

fetch_device() { # serial -> DEVICE_* globals; rc 1 with message on error
    local serial="$1" dev srv al
    case "$serial" in
        ""|*[!A-Z0-9]*) echo "  ${C_RED}✖ invalid serial '$serial'${C_RESET} ${C_DIM}(A-Z/0-9 only)${C_RESET}"; return 1 ;;
    esac
    if ! dev=$(api GET "/orgDevices/${serial}" 2>/dev/null); then
        case "$dev" in
            API_404*)        echo "  ${C_RED}✖ ${serial} not found in ABM${C_RESET}" ;;
            API_401*|API_403*) echo "  ${C_RED}✖ auth error querying ${serial}${C_RESET} ${C_DIM}— check credentials / token scope${C_RESET}" ;;
            API_429*)        echo "  ${C_RED}✖ rate limited by Apple${C_RESET} ${C_DIM}— wait a moment and retry${C_RESET}" ;;
            *)               echo "  ${C_RED}✖ API error querying ${serial}${C_RESET} ${C_DIM}${dev}${C_RESET}" ;;
        esac
        return 1
    fi
    DEVICE_ID=$(echo "$dev" | jq -r '.data.id')
    DEVICE_MODEL=$(echo "$dev" | jq -r '.data.attributes.deviceModel // "?"')
    DEVICE_FAMILY=$(echo "$dev" | jq -r '.data.attributes.productFamily // "?"')
    DEVICE_STATUS=$(echo "$dev" | jq -r '.data.attributes.status // "?"')
    DEVICE_SERVER_ID=""
    DEVICE_SERVER_NAME=""
    DEVICE_ALOCK="?"
    DEVICE_ALOCK_TYPE=""
    if srv=$(api GET "/orgDevices/${DEVICE_ID}/assignedServer" 2>/dev/null); then
        DEVICE_SERVER_ID=$(echo "$srv" | jq -r '.data.id // empty')
        DEVICE_SERVER_NAME=$(echo "$srv" | jq -r '.data.attributes.serverName // empty')
    fi
    if al=$(api GET "/orgDevices/${DEVICE_ID}/activationLockStatus" 2>/dev/null); then
        if [ "$(echo "$al" | jq -r '.data.attributes.isLocked')" = "true" ]; then
            DEVICE_ALOCK="ON"
            DEVICE_ALOCK_TYPE=$(echo "$al" | jq -r '.data.attributes.lockType // "?"')
        else
            DEVICE_ALOCK="OFF"
        fi
    fi
    csv_row "$serial"   # inventory trail — every observed device state lands in the CSV when enabled
    return 0
}

print_device() { # serial — renders the card from DEVICE_* globals
    local serial="$1"
    echo ""
    echo "  ${C_BOLD}${C_CYAN}● ${serial}${C_RESET}"
    echo "  ${C_DIM}├─${C_RESET} model    ${DEVICE_MODEL} ${C_DIM}(${DEVICE_FAMILY})${C_RESET}"
    echo "  ${C_DIM}├─${C_RESET} status   $(color_status "$DEVICE_STATUS")"
    case "$DEVICE_ALOCK" in
        ON)  echo "  ${C_DIM}├─${C_RESET} actlock  ${C_RED}ON (${DEVICE_ALOCK_TYPE})${C_RESET} — disable before disposal" ;;
        OFF) echo "  ${C_DIM}├─${C_RESET} actlock  ${C_GREEN}OFF${C_RESET}" ;;
        *)   echo "  ${C_DIM}├─${C_RESET} actlock  ${C_DIM}unknown${C_RESET}" ;;
    esac
    if [ -n "$DEVICE_SERVER_ID" ]; then
        echo "  ${C_DIM}└─${C_RESET} server   ${DEVICE_SERVER_NAME:-?} ${C_DIM}(${DEVICE_SERVER_ID})${C_RESET}"
    else
        echo "  ${C_DIM}└─${C_RESET} server   ${C_DIM}(not assigned)${C_RESET}"
    fi
    echo ""
}

show_device() { # serial — full lookup: fetch + print + audit
    fetch_device "$1" || return 1
    print_device "$1"
    audit LOOKUP "$1" "status=${DEVICE_STATUS} server=${DEVICE_SERVER_ID:-none} actlock=${DEVICE_ALOCK}"
}

confirm() { # prompt -> 0 if user typed yes
    local ans
    read -rp "$1 [y/N] " ans
    [ "$ans" = "y" ] || [ "$ans" = "Y" ] || [ "$ans" = "yes" ]
}

confirm_yes() { # prompt -> 0 if confirmed; auto-confirms when --yes was given
    if [ "$YES" = "1" ]; then
        echo "  ${C_DIM}--yes: auto-confirmed${C_RESET}"
        return 0
    fi
    confirm "$1"
}

release_banner() {
    echo ""
    echo "  ${C_RED}${C_BOLD}!! RELEASE IS PERMANENT${C_RESET}${C_RED} — the device leaves your org. It can only be"
    echo "  !! re-added via Apple Configurator / authorized reseller, and Activation"
    echo "  !! Lock management via ABM stops working. Never release a device that"
    echo "  !! may go to Apple for repair.${C_RESET}"
}

release_guard() { # pre-release checklist, uses DEVICE_* globals -> 0 ok to proceed
    local problems=0
    echo ""
    echo "  ${C_BOLD}pre-release checklist:${C_RESET}"
    case "$DEVICE_ALOCK" in
        ON)
            echo "  ${C_RED}✖ Activation Lock is ON (${DEVICE_ALOCK_TYPE:-unknown})${C_RESET} — a released device stays locked to the owner's Apple ID"
            problems=1 ;;
        OFF)
            echo "  ${C_GREEN}✔ Activation Lock OFF${C_RESET}" ;;
        *)
            echo "  ${C_YELLOW}? Activation Lock status unknown${C_RESET} ${C_DIM}— verify in business.apple.com if unsure${C_RESET}" ;;
    esac
    if [ -n "$DEVICE_SERVER_ID" ]; then
        echo "  ${C_YELLOW}⚠ still assigned to ${DEVICE_SERVER_NAME:-$DEVICE_SERVER_ID}${C_RESET} ${C_DIM}— unassign first for a clean handoff${C_RESET}"
        problems=1
    else
        echo "  ${C_GREEN}✔ not assigned to an MDM server${C_RESET}"
    fi
    [ "$problems" = "0" ] && return 0
    if [ "$FORCE" = "1" ]; then
        echo "  ${C_YELLOW}--force: proceeding despite checklist warnings${C_RESET}"
        return 0
    fi
    if [ "$YES" = "1" ]; then
        echo "  ${C_RED}✖ checklist problems — --yes does not override them; rerun with --force if intentional${C_RESET}"
        return 1
    fi
    confirm "  proceed with release despite the above?"
}

poll_activity() { # activity_id -> attributes JSON on stdout; rc 0 terminal, rc 2 still IN_PROGRESS
    local id="$1" i attrs=""
    for i in $(seq 1 "$POLL_MAX"); do
        if attrs=$(api GET "/orgDeviceActivities/${id}" 2>/dev/null); then
            attrs=$(echo "$attrs" | jq -c '.data.attributes')
            case "$(echo "$attrs" | jq -r '.status')" in
                IN_PROGRESS) sleep "$POLL_INTERVAL" ;;
                *) echo "$attrs"; return 0 ;;
            esac
        else
            sleep "$POLL_INTERVAL"  # transient API error — keep polling within budget
        fi
    done
    echo "$attrs"
    return 2
}

print_activity_result() { # attributes JSON
    local attrs="$1" st sub created
    st=$(echo "$attrs" | jq -r '.status // "?"')
    sub=$(echo "$attrs" | jq -r '.subStatus // "?"')
    created=$(echo "$attrs" | jq -r '.createdDateTime // "?"')
    if [ "$st" = "COMPLETED" ]; then
        echo "  ${C_GREEN}✔ $(color_status "$st")${C_RESET}"
    else
        echo "  ${C_RED}✖ $(color_status "$st")${C_RESET}"
    fi
    echo "  ${C_DIM}├─${C_RESET} subStatus  ${sub}"
    echo "  ${C_DIM}└─${C_RESET} created    ${C_DIM}${created}${C_RESET}"
}

wait_activity() { # activity_id [context] -> rc 0 COMPLETED, 1 FAILED, 2 still pending
    local id="$1" ctx="${2:-activity}" attrs rc=0 st
    attrs=$(poll_activity "$id") && rc=0 || rc=$?
    if [ "$rc" = "2" ]; then
        echo "  ${C_YELLOW}⏳ still IN_PROGRESS after $((POLL_MAX * POLL_INTERVAL))s — it has NOT failed${C_RESET}"
        echo "  ${C_DIM}└─${C_RESET} check later: ${C_CYAN}$0 status ${id}${C_RESET}"
        audit PENDING "$id" "$ctx"
        slack_notify "⏳ ABM activity still pending after $((POLL_MAX * POLL_INTERVAL))s: ${ctx} (id ${id})"
        return 2
    fi
    print_activity_result "$attrs"
    st=$(echo "$attrs" | jq -r '.status // "?"')
    audit "RESULT_${st}" "$id" "$ctx"
    if [ "$st" = "COMPLETED" ]; then
        slack_notify "✅ ABM ${ctx} — COMPLETED"
        return 0
    fi
    slack_notify "❌ ABM ${ctx} — ${st} (subStatus: $(echo "$attrs" | jq -r '.subStatus // "?"'))"
    return 1
}

do_activity() { # activity_type serial [server_id] -> rc 0 if COMPLETED
    local atype="$1" serial="$2" server="${3:-}" rels body resp id
    rels=$(jq -n --arg s "$serial" '{devices:{data:[{type:"orgDevices",id:$s}]}}')
    [ -n "$server" ] && rels=$(echo "$rels" | jq --arg m "$server" '. + {mdmServer:{data:{type:"mdmServers",id:$m}}}')
    body=$(jq -n --arg t "$atype" --argjson r "$rels" \
        '{data:{type:"orgDeviceActivities",attributes:{activityType:$t},relationships:$r}}')
    if ! resp=$(echo "$body" | api POST /orgDeviceActivities -d @-); then
        echo "  ${C_RED}✖ submission failed${C_RESET} ${C_DIM}$resp${C_RESET}"
        audit SUBMIT_FAILED "$serial" "$atype"
        slack_notify "❌ ABM ${atype} ${serial} — submission failed"
        return 1
    fi
    id=$(echo "$resp" | jq -r '.data.id')
    audit SUBMIT "$serial" "${atype} id=${id}$([ -n "$server" ] && echo " server=${server}")"
    echo "  ${C_CYAN}▸ activity submitted${C_RESET}"
    echo "  ${C_DIM}├─${C_RESET} id         ${C_DIM}${id}${C_RESET}"
    echo "  ${C_DIM}└─${C_RESET} ${C_YELLOW}⏳ polling…${C_RESET}"
    wait_activity "$id" "${atype} ${serial}$([ -n "$server" ] && echo " → ${server}")"
}

alock_action() {
    local serial="$1"
    if [ "$MOCK" = "1" ]; then
        if confirm "  turn OFF Activation Lock for $serial? (mock)"; then
            rm -f "$MOCK_STATE_DIR/$serial.alock"
            echo "  ${C_GREEN}✔ Activation Lock OFF${C_RESET} ${C_DIM}(simulated)${C_RESET}"
            audit ACTLOCK "$serial" "turned off (mock)"
        else
            echo "  ${C_DIM}cancelled${C_RESET}"
        fi
        return
    fi
    echo "  ${C_YELLOW}⚠ Apple's API can only READ Activation Lock status — turning it off${C_RESET}"
    echo "  ${C_YELLOW}  is web-UI-only and irreversible:${C_RESET}"
    echo "  ${C_DIM}  business.apple.com → Devices → search '$serial' → More (…) → 'Turn Off Activation Lock'${C_RESET}"
    if confirm "  open business.apple.com devices page now?"; then
        open "https://business.apple.com/#main/devices"
        echo "  ${C_DIM}opened in browser — finish there, then re-query this serial to confirm OFF${C_RESET}"
        audit ACTLOCK "$serial" "deep-linked to web UI to disable"
    fi
}

change_server() {
    local serial="$1" servers count choice sid sname
    servers=$(list_servers)
    [ -n "$servers" ] || { echo "  ${C_RED}✖ no MDM servers returned by API${C_RESET}"; return; }
    echo "  ${C_BOLD}MDM servers in ABM:${C_RESET}"
    local i=0 lsid lname
    while IFS=$'\t' read -r lsid lname; do
        i=$((i + 1))
        printf '    %s%d)%s %s %s(%s)%s\n' "$C_CYAN" "$i" "$C_RESET" "$lname" "$C_DIM" "$lsid" "$C_RESET"
    done <<< "$servers"
    count=$(echo "$servers" | wc -l | tr -d ' ')
    read -rp "  assign to server # [1-$count, or Enter to cancel]: " choice
    case "$choice" in ''|*[!0-9]*) echo "  ${C_DIM}cancelled${C_RESET}"; return ;; esac
    [ "$choice" -ge 1 ] && [ "$choice" -le "$count" ] || { echo "  ${C_DIM}cancelled${C_RESET}"; return; }
    sid=$(echo "$servers" | sed -n "${choice}p" | cut -f1)
    sname=$(echo "$servers" | sed -n "${choice}p" | cut -f2)
    if [ "$sid" = "$DEVICE_SERVER_ID" ]; then
        echo "  ${C_YELLOW}⚠ device is already on $sname — nothing to do${C_RESET}"
        return
    fi
    if confirm "  ASSIGN $serial → ${C_CYAN}$sname${C_RESET}?"; then
        do_activity ASSIGN_DEVICES "$serial" "$sid" || true
    else
        echo "  ${C_DIM}cancelled${C_RESET}"
    fi
}

main_loop() {
    while true; do
        echo "${C_DIM}───────────────────────────────────────────────${C_RESET}"
        read -rp "device serial (q to quit): " serial
        case "$serial" in q|Q|quit|exit|"") break ;; esac
        serial=$(echo "$serial" | tr '[:lower:]' '[:upper:]')
        show_device "$serial" || continue
        while true; do
            echo "  ${C_CYAN}1)${C_RESET} change MDM server"
            echo "  ${C_CYAN}2)${C_RESET} unassign from current server"
            echo "  ${C_RED}3)${C_RESET} RELEASE from ABM ${C_DIM}(permanent)${C_RESET}"
            [ "$DEVICE_ALOCK" = "ON" ] && echo "  ${C_RED}4)${C_RESET} turn off Activation Lock ${C_DIM}(currently ON)${C_RESET}"
            echo "  ${C_CYAN}5)${C_RESET} back — different device"
            read -rp "  choice: " c
            case "$c" in
                1) change_server "$serial"; break ;;
                2)
                    [ -n "$DEVICE_SERVER_ID" ] || { echo "  ${C_YELLOW}⚠ not assigned to a server${C_RESET}"; continue; }
                    if confirm "  UNASSIGN $serial from ${C_CYAN}${DEVICE_SERVER_NAME:-$DEVICE_SERVER_ID}${C_RESET}?"; then
                        do_activity UNASSIGN_DEVICES "$serial" "$DEVICE_SERVER_ID" || true
                    else
                        echo "  ${C_DIM}cancelled${C_RESET}"
                    fi
                    break ;;
                3)
                    release_banner
                    if release_guard; then
                        local check
                        read -rp "  re-type the serial (${serial}) to confirm release: " check
                        if [ "$check" = "$serial" ]; then
                            audit RELEASE_CONFIRMED "$serial" "re-typed serial in interactive session"
                            do_activity RELEASE_DEVICES "$serial" || true
                        else
                            echo "  ${C_YELLOW}⚠ serial mismatch — cancelled${C_RESET}"
                        fi
                    else
                        echo "  ${C_DIM}cancelled${C_RESET}"
                    fi
                    break ;;
                4)
                    [ "$DEVICE_ALOCK" = "ON" ] || { echo "  ${C_DIM}Activation Lock is not ON${C_RESET}"; continue; }
                    alock_action "$serial"; break ;;
                5|q|"") break ;;
                *) echo "  ${C_DIM}pick a menu number${C_RESET}" ;;
            esac
        done
    done
    echo "${C_DIM}bye.${C_RESET}"
}

# ---------- one-shot subcommands ----------
cmd_servers() {
    echo "  ${C_BOLD}MDM servers in ABM:${C_RESET}"
    list_servers | while IFS=$'\t' read -r lsid lname; do
        printf '    %s%s%s %s(%s)%s\n' "$C_CYAN" "$lname" "$C_RESET" "$C_DIM" "$lsid" "$C_RESET"
    done
}

cmd_lookup() { # serial...
    local s rc=0
    for s in "$@"; do
        s=$(echo "$s" | tr '[:lower:]' '[:upper:]')
        show_device "$s" || rc=1
    done
    return $rc
}

cmd_assign() { # serial server_id
    local serial sid
    serial=$(echo "$1" | tr '[:lower:]' '[:upper:]'); sid="$2"
    fetch_device "$serial" || return 1
    print_device "$serial"
    if [ "$DEVICE_SERVER_ID" = "$sid" ]; then
        echo "  ${C_YELLOW}⚠ already assigned to $sid — nothing to do${C_RESET}"
        return 0
    fi
    confirm_yes "  ASSIGN $serial → ${C_CYAN}$sid${C_RESET}?" || { echo "  ${C_DIM}cancelled${C_RESET}"; return 1; }
    do_activity ASSIGN_DEVICES "$serial" "$sid"
}

cmd_unassign() { # serial
    local serial
    serial=$(echo "$1" | tr '[:lower:]' '[:upper:]')
    fetch_device "$serial" || return 1
    print_device "$serial"
    [ -n "$DEVICE_SERVER_ID" ] || { echo "  ${C_YELLOW}⚠ not assigned to a server${C_RESET}"; return 0; }
    confirm_yes "  UNASSIGN $serial from ${C_CYAN}${DEVICE_SERVER_NAME:-$DEVICE_SERVER_ID}${C_RESET}?" \
        || { echo "  ${C_DIM}cancelled${C_RESET}"; return 1; }
    do_activity UNASSIGN_DEVICES "$serial" "$DEVICE_SERVER_ID"
}

cmd_release() { # serial
    local serial
    serial=$(echo "$1" | tr '[:lower:]' '[:upper:]')
    fetch_device "$serial" || return 1
    print_device "$serial"
    release_banner
    release_guard || { echo "  ${C_DIM}cancelled${C_RESET}"; return 1; }
    confirm_yes "  ${C_RED}RELEASE $serial permanently from ABM?${C_RESET}" || { echo "  ${C_DIM}cancelled${C_RESET}"; return 1; }
    audit RELEASE_CONFIRMED "$serial" "confirmed non-interactively (force=${FORCE})"
    do_activity RELEASE_DEVICES "$serial"
}

cmd_status() { # activity_id
    echo "  ${C_CYAN}▸ activity ${1}${C_RESET}"
    wait_activity "$1" "status check $1"
}

cmd_batch() { # file — rows: serial[,action[,server_id]] ; '#' comments and blanks ignored
    local file="$1" line serial action sid n=0
    [ -f "$file" ] || die "batch file not found: $file"
    local -a rows=()
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        line=$(echo "$line" | tr -d '[:space:]')
        [ -n "$line" ] && rows+=("$line")
    done < "$file"
    [ "${#rows[@]}" -gt 0 ] || die "batch file has no actionable rows: $file"
    local c_lookup=0 c_assign=0 c_unassign=0 c_release=0 i
    for ((i = 0; i < ${#rows[@]}; i++)); do
        action=$(echo "${rows[$i]}" | cut -d, -s -f2); action=${action:-lookup}
        case "$action" in
            lookup)   c_lookup=$((c_lookup + 1)) ;;
            assign)   c_assign=$((c_assign + 1)) ;;
            unassign) c_unassign=$((c_unassign + 1)) ;;
            release)  c_release=$((c_release + 1)) ;;
            *) die "unknown action '$action' in batch row: ${rows[$i]}" ;;
        esac
    done
    echo "  ${C_BOLD}batch:${C_RESET} ${#rows[@]} rows — ${c_lookup} lookup, ${c_assign} assign, ${c_unassign} unassign, ${C_RED}${c_release} release${C_RESET}"
    confirm_yes "  run batch from ${file}?" || { echo "  ${C_DIM}cancelled${C_RESET}"; return 1; }
    local ok=0 fail=0
    for ((i = 0; i < ${#rows[@]}; i++)); do
        serial=$(echo "${rows[$i]}" | cut -d, -f1 | tr '[:lower:]' '[:upper:]')
        action=$(echo "${rows[$i]}" | cut -d, -s -f2); action=${action:-lookup}
        sid=$(echo "${rows[$i]}" | cut -d, -s -f3)
        n=$((n + 1))
        echo "${C_DIM}───────────────────────────────────────────────${C_RESET}"
        echo "  ${C_BOLD}[${n}/${#rows[@]}]${C_RESET} ${action} ${C_CYAN}${serial}${C_RESET}"
        case "$action" in
            lookup)   cmd_lookup "$serial" ;;
            assign)   if [ -z "$sid" ]; then
                          echo "  ${C_RED}✖ assign needs a server_id in column 3${C_RESET}"
                          fail=$((fail + 1)); continue
                      fi
                      cmd_assign "$serial" "$sid" ;;
            unassign) cmd_unassign "$serial" ;;
            release)  cmd_release "$serial" ;;
        esac && ok=$((ok + 1)) || fail=$((fail + 1))
    done
    echo "${C_DIM}───────────────────────────────────────────────${C_RESET}"
    echo "  ${C_BOLD}batch done:${C_RESET} ${C_GREEN}${ok} ok${C_RESET}, ${C_RED}${fail} failed${C_RESET}"
    audit BATCH "$file" "rows=${#rows[@]} ok=${ok} fail=${fail}"
    slack_notify "ABM batch finished: ${ok} ok, ${fail} failed out of ${#rows[@]} rows (${file})"
    [ "$fail" = "0" ]
}

# ---------- dispatch ----------
case "${1:-}" in -h|--help|help) show_help; exit 0 ;; esac

need jq; need curl; need openssl; need xxd

# shared flags are accepted anywhere on the command line
ARGS=()
for a in "$@"; do
    case "$a" in
        -y|--yes) YES=1 ;;
        --force)  FORCE=1 ;;
        *)        ARGS+=("$a") ;;
    esac
done
set -- ${ARGS[@]+"${ARGS[@]}"}

CMD=""
case "${1:-}" in
    lookup|assign|unassign|release|status|servers|batch) CMD="$1"; shift ;;
esac

if [ "$MOCK" = "1" ]; then
    if [ -n "${ABM_MOCK_STATE_DIR:-}" ]; then
        MOCK_STATE_DIR="$ABM_MOCK_STATE_DIR"   # persists across runs — survives process exit
        mkdir -p "$MOCK_STATE_DIR"
    else
        MOCK_STATE_DIR=$(mktemp -d -t abm_mock)
        MOCK_STATE_OWNED="$MOCK_STATE_DIR"
    fi
    if [ ! -e "$MOCK_STATE_DIR/.seeded" ]; then
        echo "SRV-JAMF-PROD" > "$MOCK_STATE_DIR/DEMO1234XYZ.server"  # starts assigned
        echo "MDM" > "$MOCK_STATE_DIR/DEMO1234XYZ.alock"            # starts Activation Locked
        touch "$MOCK_STATE_DIR/.seeded"
    fi
else
    load_config
fi

load_integrations
validate_integrations
get_token

case "$CMD" in
    "")
        if [ "$MOCK" = "1" ]; then
            echo "mock devices: ${C_CYAN}DEMO1234XYZ${C_RESET} (assigned, actlock ON) ${C_DIM}|${C_RESET} ${C_CYAN}DEMO5678ABC${C_RESET} (unassigned) ${C_DIM}|${C_RESET} anything else = not found"
        fi
        main_loop
        ;;
    lookup)   [ $# -ge 1 ] || die "usage: $0 lookup SERIAL [SERIAL...]"
              cmd_lookup "$@" ;;
    servers)  cmd_servers ;;
    assign)   [ $# -eq 2 ] || die "usage: $0 assign SERIAL SERVER_ID [--yes]  (server ids: $0 servers)"
              cmd_assign "$1" "$2" ;;
    unassign) [ $# -eq 1 ] || die "usage: $0 unassign SERIAL [--yes]"
              cmd_unassign "$1" ;;
    release)  [ $# -eq 1 ] || die "usage: $0 release SERIAL [--yes] [--force]"
              cmd_release "$1" ;;
    status)   [ $# -eq 1 ] || die "usage: $0 status ACTIVITY_ID"
              cmd_status "$1" ;;
    batch)    [ $# -eq 1 ] || die "usage: $0 batch FILE.csv [--yes] [--force]"
              cmd_batch "$1" ;;
esac
