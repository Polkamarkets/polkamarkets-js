#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════
# create_clob_markets.sh — Create CLOB markets or neg-risk events
#
# Modes:
#   1) Regular — batch-create independent binary (YES/NO) CLOB markets
#   2) Neg-risk — create a multi-outcome event via NegRiskAdapter
#
# Oracle support (regular mode only):
#   - No oracle (admin-only resolution)
#   - Realitio oracle (human-answered questions)
#
# Auto-loads defaults from the most recent deploy env file if available.
# ═══════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"
ROOT_DIR="$(dirname "${REPO_DIR}")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

banner() { echo -e "\n${CYAN}═══════════════════════════════════════════════════${NC}"; echo -e "${CYAN}  $1${NC}"; echo -e "${CYAN}═══════════════════════════════════════════════════${NC}\n"; }
info()    { echo -e "${BLUE}ℹ${NC}  $1"; }
success() { echo -e "${GREEN}✓${NC}  $1"; }
warn()    { echo -e "${YELLOW}⚠${NC}  $1"; }
error()   { echo -e "${RED}✗${NC}  $1"; }

prompt_secret() {
  local var_name="$1"
  local prompt="$2"
  if [[ -z "${!var_name:-}" ]]; then
    read -r -s -p "  ${prompt}: " value
    echo
    export "${var_name}=${value}"
  fi
}

prompt_value() {
  local var_name="$1"
  local prompt="$2"
  local default_value="${3:-}"
  if [[ -z "${!var_name:-}" ]]; then
    if [[ -n "${default_value}" ]]; then
      read -r -p "  ${prompt} [${default_value}]: " value
      value="${value:-$default_value}"
    else
      read -r -p "  ${prompt}: " value
    fi
    export "${var_name}=${value}"
  fi
}

run_forge() {
  local description="$1"
  shift
  local output=""
  local exit_code=0

  info "${description}..."
  output=$("$@" 2>&1) || exit_code=$?

  echo "${output}"

  if echo "${output}" | grep -q "ONCHAIN EXECUTION COMPLETE & SUCCESSFUL"; then
    success "${description} — confirmed on-chain"
    FORGE_OUTPUT="${output}"
    return 0
  fi

  if [[ ${exit_code} -ne 0 ]]; then
    error "${description} failed (exit code ${exit_code})"
    return 1
  fi

  FORGE_OUTPUT="${output}"
}

# ═══════════════════════════════════════════════════════════════════════
# Load defaults
# ═══════════════════════════════════════════════════════════════════════
banner "Create CLOB Markets"

# Try to load from root .env
if [[ -f "${ROOT_DIR}/.env" ]]; then
  source "${ROOT_DIR}/.env"
  info "Loaded defaults from ${ROOT_DIR}/.env"
fi

# Try to load from most recent deploy env
LATEST_DEPLOY=$(ls -t "${ROOT_DIR}/scripts/.deploy_bnb_"*.env 2>/dev/null | head -1 || true)
if [[ -n "${LATEST_DEPLOY}" && -f "${LATEST_DEPLOY}" ]]; then
  source "${LATEST_DEPLOY}"
  info "Loaded deploy defaults from ${LATEST_DEPLOY}"
fi

# ═══════════════════════════════════════════════════════════════════════
# Mode selection
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo -e "${YELLOW}Market type:${NC}"
echo "  1) Regular — independent binary (YES/NO) markets"
if [[ -n "${CLOB_NEG_RISK_ADAPTER:-}" ]]; then
  echo "  2) Neg-risk — multi-outcome event (e.g. Trump/Harris/Biden)"
else
  echo -e "  2) Neg-risk ${RED}(unavailable — NEG_RISK_ADAPTER not in deploy env)${NC}"
fi
read -r -p "  Choose [1/2]: " MODE_CHOICE
MODE_CHOICE="${MODE_CHOICE:-1}"

# ═══════════════════════════════════════════════════════════════════════
# Configuration
# ═══════════════════════════════════════════════════════════════════════
banner "Configuration"

# Signing uses an encrypted keystore account (one-time: `cast wallet import <name>
# --interactive`). The private key is never read into the environment or a
# plaintext file — only the account name and the public signer address.
prompt_value "ACCOUNT" "Keystore account name (cast wallet import <name>)" "${ACCOUNT:-}"
prompt_value "SENDER" "Signer address (0x...)" "${SENDER:-}"

prompt_value "RPC_URL" "RPC URL" "${CLOB_RPC_URL:-${RPC_URL:-}}"
prompt_value "CLOB_MANAGER" "CLOB_MANAGER address" "${CLOB_MANAGER:-}"
prompt_value "CLOB_FEE_MODULE" "CLOB_FEE_MODULE address" "${CLOB_FEE_MODULE:-}"

if [[ "${MODE_CHOICE}" == "2" ]]; then
  # ─── Neg-risk mode ───
  if [[ -z "${CLOB_NEG_RISK_ADAPTER:-}" ]]; then
    error "NEG_RISK_ADAPTER address not available. Deploy the adapter first or set CLOB_NEG_RISK_ADAPTER."
    exit 1
  fi

  prompt_value "NEG_RISK_ADAPTER" "NegRiskAdapter address" "${CLOB_NEG_RISK_ADAPTER:-}"

  unset QUESTION OUTCOMES 2>/dev/null || true
  prompt_value "QUESTION" "Event question (e.g. \"Who will win the election?\")"
  prompt_value "OUTCOMES" "Comma-separated outcome names (e.g. \"Trump,Harris,Biden\")"

  IFS=',' read -ra OUTCOME_ARRAY <<< "${OUTCOMES}"
  MARKET_COUNT="${#OUTCOME_ARRAY[@]}"
  if [[ "${MARKET_COUNT}" -lt 2 ]]; then
    error "Neg-risk events require at least 2 outcomes."
    exit 1
  fi

  read -r -p "  Close offset (seconds from now) [86400]: " CLOSE_OFFSET
  CLOSE_OFFSET="${CLOSE_OFFSET:-86400}"

  read -r -p "  Image URL (optional): " IMAGE
  IMAGE="${IMAGE:-}"
  export IMAGE

  NOW_TS="$(date +%s)"
  export CLOSES_AT="$((NOW_TS + CLOSE_OFFSET))"
  export OUTCOMES QUESTION NEG_RISK_ADAPTER CLOB_FEE_MODULE

  read -r -p "  Set fees for all outcome markets? [y/N]: " SET_FEES
  SET_FEES="${SET_FEES:-N}"
  SET_FEES="$(printf '%s' "${SET_FEES}" | tr '[:upper:]' '[:lower:]')"

  if [[ "${SET_FEES}" == "y" || "${SET_FEES}" == "yes" ]]; then
    read -r -p "  MAKER_FEE_BPS [100]: " MAKER_FEE_BPS
    MAKER_FEE_BPS="${MAKER_FEE_BPS:-100}"
    read -r -p "  TAKER_FEE_BPS [200]: " TAKER_FEE_BPS
    TAKER_FEE_BPS="${TAKER_FEE_BPS:-200}"
    read -r -p "  Fee curve? Peak at centre, 0 at edges [y/N]: " USE_CURVE
    USE_CURVE="${USE_CURVE:-N}"
    USE_CURVE="$(printf '%s' "${USE_CURVE}" | tr '[:upper:]' '[:lower:]')"
  fi

  # ─── Summary ───
  echo ""
  success "Configuration:"
  echo -e "  ${YELLOW}Mode:${NC}       Neg-risk event"
  echo -e "  ${YELLOW}Adapter:${NC}    ${NEG_RISK_ADAPTER}"
  echo -e "  ${YELLOW}FeeModule:${NC}  ${CLOB_FEE_MODULE}"
  echo -e "  ${YELLOW}Question:${NC}   ${QUESTION}"
  echo -e "  ${YELLOW}Outcomes:${NC}   ${OUTCOMES} (${MARKET_COUNT} markets)"
  echo -e "  ${YELLOW}Closes at:${NC}  ${CLOSES_AT} ($(date -r "${CLOSES_AT}" 2>/dev/null || date -d "@${CLOSES_AT}" 2>/dev/null || echo "${CLOSES_AT}"))"
  [[ "${SET_FEES}" == "y" || "${SET_FEES}" == "yes" ]] && echo -e "  ${YELLOW}Fees:${NC}       maker ${MAKER_FEE_BPS} bps / taker ${TAKER_FEE_BPS} bps"
  echo ""

  read -r -p "  Continue? [Y/n]: " CONFIRM
  CONFIRM="${CONFIRM:-y}"
  if [[ ! "${CONFIRM}" =~ ^[Yy] ]]; then
    info "Aborted."
    exit 0
  fi

  # ─── Create neg-risk event ───
  banner "Creating Neg-Risk Event"

  cd "${REPO_DIR}"

  FORGE_OUTPUT=""
  if ! run_forge "Create neg-risk event" \
    forge script script/CreateNegRiskEvent.s.sol:CreateNegRiskEvent \
      --rpc-url "${RPC_URL}" \
      --account "${ACCOUNT}" --sender "${SENDER}" \
      --broadcast; then
    error "Neg-risk event creation failed."
    exit 1
  fi

  echo ""
  success "Neg-risk event created!"

  # ─── Set fees ───
  if [[ "${SET_FEES}" == "y" || "${SET_FEES}" == "yes" ]]; then
    EVENT_OUTPUT="${FORGE_OUTPUT}"
    OUTCOME_COUNT=$(echo "${EVENT_OUTPUT}" | sed -n 's/.*Outcomes: \([0-9]*\).*/\1/p' | head -1) || true
    OUTCOME_COUNT="${OUTCOME_COUNT:-${MARKET_COUNT}}"

    LATEST_MARKET_COUNT=$(cast call "${CLOB_MANAGER}" "marketCount()(uint256)" --rpc-url "${RPC_URL}" 2>/dev/null || echo "0")
    LATEST_MARKET_COUNT=$((LATEST_MARKET_COUNT))

    if [[ "${LATEST_MARKET_COUNT}" -gt 0 && "${OUTCOME_COUNT}" -gt 0 ]]; then
      FIRST_ID=$((LATEST_MARKET_COUNT - OUTCOME_COUNT))
      export MAKER_FEE_BPS TAKER_FEE_BPS
      [[ "${USE_CURVE:-n}" == "y" || "${USE_CURVE:-n}" == "yes" ]] && export FEE_CURVE=true || export FEE_CURVE=false

      for (( i=FIRST_ID; i<LATEST_MARKET_COUNT; i++ )); do
        export MARKET_ID="${i}"
        FORGE_OUTPUT=""
        if ! run_forge "Set fees for market #${i}" \
          forge script script/SetCLOBFees.s.sol:SetCLOBFees \
            --rpc-url "${RPC_URL}" \
            --account "${ACCOUNT}" --sender "${SENDER}" \
            --broadcast; then
          warn "Fee setting failed for market #${i}, continuing..."
        else
          success "Fees set for market #${i}"
        fi
      done
    else
      warn "Could not determine market IDs. Set fees manually with SetCLOBFees."
    fi
  fi

  # ─── Done ───
  banner "Done!"

  echo -e "${GREEN}Created neg-risk event with ${MARKET_COUNT} outcome market(s).${NC}"
  echo ""
  echo -e "${YELLOW}Next:${NC} Run the cron to sync to the API database:"
  echo "  cd myriad-protocol-api && ./scripts/cron-jobs.sh"
  echo ""

  exit 0
fi

# ═══════════════════════════════════════════════════════════════════════
# Regular mode — independent binary markets
# ═══════════════════════════════════════════════════════════════════════

unset ORACLE ARBITRATOR REALITIO_TIMEOUT 2>/dev/null || true

echo ""
echo -e "${YELLOW}Oracle type for all markets:${NC}"
echo "  1) No oracle (admin-only resolution)"
echo "  2) Realitio (human-answered questions)"
if [[ -n "${CRE_ORACLE:-}" ]]; then
  echo "  3) CRE (Chainlink deterministic crypto)"
else
  echo -e "  3) CRE ${RED}(unavailable — CRE_ORACLE not in deploy env)${NC}"
fi
read -r -p "  Choose [1-3]: " ORACLE_CHOICE
ORACLE_CHOICE="${ORACLE_CHOICE:-1}"

ORACLE_TYPE="none"
ORACLE_ADDR="0x0000000000000000000000000000000000000000"

case "${ORACLE_CHOICE}" in
  2)
    ORACLE_TYPE="realitio"
    prompt_value "ORACLE" "RealitioOracle address" "${REALITIO_ORACLE:-}"
    ORACLE_ADDR="${ORACLE}"
    prompt_value "ARBITRATOR" "Reality.eth arbitrator address"
    read -r -p "  Realitio timeout in seconds [3600]: " REALITIO_TIMEOUT_INPUT
    export REALITIO_TIMEOUT="${REALITIO_TIMEOUT_INPUT:-3600}"
    export ARBITRATOR
    ;;
  3)
    ORACLE_TYPE="cre"
    if [[ -z "${CRE_ORACLE:-}" ]]; then
      error "CRE_ORACLE address not available. Deploy the CRE oracle first."
      exit 1
    fi
    ORACLE_ADDR="${CRE_ORACLE}"

    echo -e "  ${YELLOW}CRE Rule types:${NC} 0=Threshold 1=Direction 2=Change% 3=Relative 4=Hit 5=Candle"
    read -r -p "  Rule type [1]: " RULE_TYPE
    export RULE_TYPE="${RULE_TYPE:-1}"

    read -r -p "  YES when above? (true/false) [true]: " YES_ABOVE
    export YES_ABOVE="${YES_ABOVE:-true}"

    read -r -p "  Feed ID (e.g. BTCUSDT) [BTCUSDT]: " FEED_ID
    export FEED_ID="${FEED_ID:-BTCUSDT}"

    read -r -p "  Second feed (Relative only, empty otherwise): " FEED_ID_B
    export FEED_ID_B="${FEED_ID_B:-}"

    read -r -p "  Param (price 8-dec / bps / candle interval) [0]: " PARAM
    export PARAM="${PARAM:-0}"

    read -r -p "  Open timestamp (unix, 0 for threshold/hit) [0]: " OPEN_TIMESTAMP
    export OPEN_TIMESTAMP="${OPEN_TIMESTAMP:-0}"
    ;;
  *)
    ORACLE_TYPE="none"
    ;;
esac

export ORACLE="${ORACLE_ADDR}"
export ORACLE_TYPE

echo ""
read -r -p "  Number of markets [10]: " MARKET_COUNT
MARKET_COUNT="${MARKET_COUNT:-10}"

read -r -p "  Question prefix [Myriad CLOB Market]: " QUESTION_PREFIX
QUESTION_PREFIX="${QUESTION_PREFIX:-Myriad CLOB Market}"

read -r -p "  Close offset (seconds from now) [86400]: " CLOSE_OFFSET
CLOSE_OFFSET="${CLOSE_OFFSET:-86400}"

read -r -p "  Close spacing (seconds between markets) [60]: " CLOSE_SPACING
CLOSE_SPACING="${CLOSE_SPACING:-60}"

read -r -p "  Image URL (optional): " IMAGE
IMAGE="${IMAGE:-}"
export IMAGE

read -r -p "  Set fees after creation? [y/N]: " SET_FEES
SET_FEES="${SET_FEES:-N}"
SET_FEES="$(printf '%s' "${SET_FEES}" | tr '[:upper:]' '[:lower:]')"

if [[ "${SET_FEES}" == "y" || "${SET_FEES}" == "yes" ]]; then
  read -r -p "  First MARKET_ID (will increment) [0]: " FIRST_MARKET_ID
  FIRST_MARKET_ID="${FIRST_MARKET_ID:-0}"
  read -r -p "  MAKER_FEE_BPS [100]: " MAKER_FEE_BPS
  MAKER_FEE_BPS="${MAKER_FEE_BPS:-100}"
  read -r -p "  TAKER_FEE_BPS [200]: " TAKER_FEE_BPS
  TAKER_FEE_BPS="${TAKER_FEE_BPS:-200}"
  read -r -p "  Fee curve? Peak at centre, 0 at edges [y/N]: " USE_CURVE
  USE_CURVE="${USE_CURVE:-N}"
  USE_CURVE="$(printf '%s' "${USE_CURVE}" | tr '[:upper:]' '[:lower:]')"
fi

# ═══════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════
echo ""
success "Configuration:"
echo -e "  ${YELLOW}Mode:${NC}       Regular binary markets"
echo -e "  ${YELLOW}Manager:${NC}    ${CLOB_MANAGER}"
echo -e "  ${YELLOW}FeeModule:${NC}  ${CLOB_FEE_MODULE}"
echo -e "  ${YELLOW}Oracle:${NC}     ${ORACLE_TYPE} (${ORACLE_ADDR})"
echo -e "  ${YELLOW}Markets:${NC}    ${MARKET_COUNT}"
echo -e "  ${YELLOW}Prefix:${NC}     ${QUESTION_PREFIX}"
echo -e "  ${YELLOW}Close:${NC}      +${CLOSE_OFFSET}s, spacing ${CLOSE_SPACING}s"
[[ "${SET_FEES}" == "y" || "${SET_FEES}" == "yes" ]] && echo -e "  ${YELLOW}Fees:${NC}       maker ${MAKER_FEE_BPS} bps / taker ${TAKER_FEE_BPS} bps"
echo ""

read -r -p "  Continue? [Y/n]: " CONFIRM
CONFIRM="${CONFIRM:-y}"
if [[ ! "${CONFIRM}" =~ ^[Yy] ]]; then
  info "Aborted."
  exit 0
fi

# ═══════════════════════════════════════════════════════════════════════
# Create markets
# ═══════════════════════════════════════════════════════════════════════
banner "Creating Markets"

cd "${REPO_DIR}"

now_ts="$(date +%s)"
CREATED_IDS=()

for ((i=1; i<=MARKET_COUNT; i++)); do
  export QUESTION="${QUESTION_PREFIX} #${i}"
  export CLOSES_AT="$((now_ts + CLOSE_OFFSET + (i - 1) * CLOSE_SPACING))"

  echo ""
  info "Market ${i}/${MARKET_COUNT}: ${QUESTION}"
  echo -e "  Closes at: ${CLOSES_AT} ($(date -r "${CLOSES_AT}" 2>/dev/null || date -d "@${CLOSES_AT}" 2>/dev/null || echo "${CLOSES_AT}"))"

  FORGE_OUTPUT=""
  if ! run_forge "Create market #${i}" \
    forge script script/CreateCLOBMarket.s.sol:CreateCLOBMarket \
      --rpc-url "${RPC_URL}" \
      --account "${ACCOUNT}" --sender "${SENDER}" \
      --broadcast; then
    warn "Market #${i} creation failed, skipping..."
    continue
  fi

  MARKET_ID=$(echo "${FORGE_OUTPUT}" | sed -n 's/.*Market created with ID: \([0-9]*\).*/\1/p' | head -1) || true
  MARKET_ID="${MARKET_ID:-?}"
  CREATED_IDS+=("${MARKET_ID}")
  success "Market #${MARKET_ID} created"

  if [[ "${SET_FEES}" == "y" || "${SET_FEES}" == "yes" ]]; then
    if [[ "${MARKET_ID}" == "?" ]]; then
      export MARKET_ID="$((FIRST_MARKET_ID + i - 1))"
    fi
    export MAKER_FEE_BPS TAKER_FEE_BPS
    if [[ "${USE_CURVE}" == "y" || "${USE_CURVE}" == "yes" ]]; then
      export FEE_CURVE=true
    else
      export FEE_CURVE=false
    fi

    if ! run_forge "Set fees for market #${MARKET_ID}" \
      forge script script/SetCLOBFees.s.sol:SetCLOBFees \
        --rpc-url "${RPC_URL}" \
        --account "${ACCOUNT}" --sender "${SENDER}" \
        --broadcast; then
      warn "Fee setting failed for market #${MARKET_ID}, continuing..."
    fi
  fi
done

# ═══════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════
banner "Done!"

echo -e "${GREEN}Created ${#CREATED_IDS[@]} market(s):${NC}"
if [[ ${#CREATED_IDS[@]} -gt 0 ]]; then
  for mid in "${CREATED_IDS[@]}"; do
    echo "  - Market #${mid}"
  done
fi
echo ""
echo -e "${YELLOW}Oracle:${NC} ${ORACLE_TYPE} (${ORACLE_ADDR})"
echo ""
echo -e "${YELLOW}Next:${NC} Run the cron to sync to the API database:"
echo "  cd myriad-protocol-api && ./scripts/cron-jobs.sh"
echo ""
