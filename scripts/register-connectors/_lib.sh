# scripts/register-connectors/_lib.sh
#
# Shared library sourced by every connector registration script.
# Do NOT execute this file directly — source it:
#   source "$(dirname "$0")/_lib.sh"
#
# Provides:
#   register_connector <name> <config_file> [--force]
#   print_status
#
# Callers set CONNECTOR_NAME and CONNECTOR_CONFIG before sourcing,
# then call register_connector and optionally print_status.

# ── Guard: must be sourced, not executed ─────────────────────────────────────
# $BASH_SOURCE[0] == $0 only when the file is executed directly.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    echo "ERROR: _lib.sh must be sourced, not executed directly." >&2
    echo "Usage: source \"\$(dirname \"\$0\")/_lib.sh\"" >&2
    exit 1
fi

# ── Shared config ─────────────────────────────────────────────────────────────
CONNECT_URL="${CONNECT_URL:-http://localhost:8083}"

# ── Colour helpers ────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[CDC]${NC} $*"; }
warn() { echo -e "${YELLOW}[CDC]${NC} $*"; }
err()  { echo -e "${RED}[CDC]${NC} $*"; exit 1; }

# ── register_connector <name> <config_file> [--force] ─────────────────────────
#
# Behaviour:
#   connector does not exist       → register it
#   connector is RUNNING, no force → skip (print message, return 0)
#   connector is RUNNING + --force → delete then re-register
#   connector is FAILED/PAUSED     → delete then re-register
#
# Arguments:
#   $1  connector name   (e.g. ecommerce-postgres-cdc)
#   $2  config file path (e.g. config/debezium/postgres-connector.json)
#   $3  optional --force flag
register_connector() {
    local name="$1"
    local config_file="$2"
    local force="${3:-}"

    # ── Validate config file exists ───────────────────────────────────────────
    [[ -f "$config_file" ]] \
        || err "[$name] Config file not found: $config_file"

    # ── Check current state ───────────────────────────────────────────────────
    local existing state
    existing=$(curl -sf "$CONNECT_URL/connectors/$name/status" 2>/dev/null || echo "")

    if [[ -n "$existing" ]]; then
        state=$(echo "$existing" \
            | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['connector']['state'])" \
            2>/dev/null || echo "UNKNOWN")

        if [[ "$state" == "RUNNING" && "$force" != "--force" ]]; then
            log "[$name] Already RUNNING — skipping."
            log "       Pass --force to delete and re-register."
            return 0
        fi

        warn "[$name] Exists with state=$state — deleting before re-registration..."
        curl -sf -X DELETE "$CONNECT_URL/connectors/$name" > /dev/null
        sleep 3
    fi

    # ── Register ──────────────────────────────────────────────────────────────
    log "[$name] Registering from $config_file ..."
    curl -sf \
        -X POST "$CONNECT_URL/connectors" \
        -H "Content-Type: application/json" \
        -d @"$config_file" > /dev/null \
        || err "[$name] POST to $CONNECT_URL/connectors failed."

    # ── Wait for RUNNING ──────────────────────────────────────────────────────
    log "[$name] Waiting for RUNNING state..."
    local i
    for i in $(seq 1 30); do
        state=$(curl -sf "$CONNECT_URL/connectors/$name/status" \
            | python3 -c \
              "import sys,json; d=json.load(sys.stdin); print(d['connector']['state'])" \
              2>/dev/null || echo "PENDING")

        printf "  [%s] [%02d/30] state: %s\n" "$name" "$i" "$state"

        [[ "$state" == "RUNNING" ]] && { log "[$name] RUNNING ✓"; return 0; }
        [[ "$state" == "FAILED"  ]] && \
            err "[$name] Reached FAILED state. Inspect with: docker logs cdc-debezium"

        sleep 3
    done

    err "[$name] Did not reach RUNNING within 90 seconds."
}

# ── print_status ──────────────────────────────────────────────────────────────
# Prints a summary table of all registered connectors and their task states.
print_status() {
    echo ""
    log "================================================="
    log " Connector status:"
    curl -sf "$CONNECT_URL/connectors?expand=status" \
        | python3 -c "
import sys, json
data = json.load(sys.stdin)
if not data:
    print('  (no connectors registered)')
for name, info in data.items():
    state   = info['status']['connector']['state']
    tasks   = info['status']['tasks']
    tstates = [t['state'] for t in tasks]
    print(f'  {name}: {state}  tasks={tstates}')
" 2>/dev/null || warn "Could not reach $CONNECT_URL"
    log "================================================="
}