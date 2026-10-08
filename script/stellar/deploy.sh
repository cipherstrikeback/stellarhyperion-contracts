#!/usr/bin/env bash
#
# Phase one of a Hyperion deployment on Stellar: upload, deploy, initialize, wire the adapters,
# and queue the router changes that have to wait.
#
# The router's timelock has no bootstrap exemption, the same as the EVM side and for the same
# reason: an exemption is a second code path that configures a router without waiting, which is
# precisely the path an attacker wants and precisely the path nobody tests after week one. So a
# fresh router is configured the way a two year old one is, and the floor is one hour of real
# time that no amount of scripting can skip on a public network.
#
# What this leaves behind is a deployed router that owns nothing yet, adapters that are fully
# configured because they are not timelocked, and a list of pending changes with timestamps.
# execute.sh finishes the job. In between, the record on disk is the handover and anybody can read
# the queued actions off the chain and check them against it.
#
# Secrets: the signing key is a named identity from `stellar keys`, held in the CLI's own config
# directory outside this repository. No secret is read from the environment, written to the record,
# or printed. Only the public address appears anywhere.
#
# Usage:
#   stellar keys generate hyperion-deploy --network testnet --fund
#   HYPERION_PEER_CHAIN=arc-testnet script/stellar/deploy.sh
source "$(dirname "$0")/lib.sh"
require_tools
require_identity

DEPLOYER=$(deployer_address)

# Who governs, and the three numbers that shape the router's behaviour. Defaults point at the
# deployer so a testnet run needs no ceremony; a real one overrides every one of them.
ADMIN="${HYPERION_ADMIN:-$DEPLOYER}"
GUARDIAN="${HYPERION_GUARDIAN:-$DEPLOYER}"
TREASURY="${HYPERION_TREASURY:-$DEPLOYER}"
FEE_BPS="${HYPERION_FEE_BPS:-30}"
# Ledgers, not seconds. Stellar closes a ledger roughly every five seconds, so 720 is about an
# hour of flow accounting. Sliding rather than calendar, so this is a window length.
FLOW_WINDOW="${HYPERION_FLOW_WINDOW_LEDGERS:-720}"
# Seconds, and the contract floor is 3600. A day is the default on a real network; testnet runs
# usually want the floor so phase two is an hour away rather than a day.
TIMELOCK="${HYPERION_TIMELOCK_DELAY:-3600}"

# The asset. On testnet this defaults to the published USDC issuer, and the contract id is derived
# from the code, the issuer and the network passphrase rather than typed by anybody.
ASSET="${HYPERION_ASSET:-USDC:GBBD47IF6LWK7P7MDEVSCWR7DPUWV3NY3DTQEVFL4NAT4AQH3ZLLFLA5}"
ASSET_CODE="${ASSET%%:*}"
FLOW_LIMIT="${HYPERION_TOKEN_FLOW_LIMIT:-10000000000000}"

PEER="$(peer_chain)"

note "who and what"
say "network          $NETWORK"
say "identity         $IDENTITY"
say "deployer         $DEPLOYER"
say "admin            $ADMIN"
say "guardian         $GUARDIAN"
say "treasury         $TREASURY"
say "fee bps          $FEE_BPS"
say "flow window      $FLOW_WINDOW ledgers"
say "timelock delay   $TIMELOCK seconds"
say "asset            $ASSET"
say "paired with      $PEER"

note "deriving the asset contract id"
SAC=$(sac_id "$ASSET")
[ -n "$SAC" ] || die "could not derive a contract id for $ASSET"
say "$ASSET_CODE  $SAC"

note "uploading"
ROUTER_HASH=$(upload "$WASM_DIR/hyperion_router.wasm")
say "router           $ROUTER_HASH"
CCTP_HASH=$(upload "$WASM_DIR/hyperion_adapter_cctp.wasm")
say "cctp adapter     $CCTP_HASH"
AXELAR_HASH=$(upload "$WASM_DIR/hyperion_adapter_axelar.wasm")
say "axelar adapter   $AXELAR_HASH"

note "deploying the router"
ROUTER=$(reuse_or_deploy HYPERION_ROUTER "$ROUTER_HASH" "router")
[ -n "$ROUTER" ] || die "router deploy produced no contract id"
say "router           $ROUTER"

# The deployer is admin for the length of the deployment and nothing longer. Handing the real admin
# straight to a cold key would mean every queued action below needs that key to sign, in a script,
# which it cannot do. The deployer queues and executes, and the last queued action hands over.
note "initializing the router"
ROUTER_LEDGER=""
if is_initialized "$ROUTER"; then
  say "already initialized, leaving it alone"
else
INIT_OUT=$(invoke "$ROUTER" initialize \
  --admin "$DEPLOYER" \
  --guardian "$GUARDIAN" \
  --treasury "$TREASURY" \
  --fee_bps "$FEE_BPS" \
  --flow_window_ledgers "$FLOW_WINDOW" \
  --timelock_delay "$TIMELOCK" 2>&1) || die "router initialize"
say "done"
ROUTER_LEDGER=$(node -e '
const out = process.argv[1] || "";
try {
  const j = JSON.parse(out);
  if (typeof j.ledger === "number") { process.stdout.write(String(j.ledger)); process.exit(0); }
  if (typeof j.latestLedger === "number") { process.stdout.write(String(j.latestLedger)); process.exit(0); }
  if (j.result && typeof j.result.ledger === "number") { process.stdout.write(String(j.result.ledger)); process.exit(0); }
} catch {}
const m = out.match(/"ledger"\s*:\s*(\d+)/i) ||
          out.match(/ledger(?:\s+sequence)?[:\s]+(\d+)/i) ||
          out.match(/in ledger\s+(\d+)/i);
if (m) process.stdout.write(m[1]);
' "$INIT_OUT")
[ -z "$ROUTER_LEDGER" ] || say "router ledger    $ROUTER_LEDGER"
fi

# ---------------------------------------------------------------------------------------------
# Adapters. Not timelocked, because they are owned rather than governed, and an adapter with no
# lanes cannot do anything at all. Their link setters are once only, so this is the only chance.
# ---------------------------------------------------------------------------------------------

CCTP=""
if [ -n "${CCTP_TOKEN_MESSENGER:-}" ] && [ -n "${CCTP_MESSAGE_TRANSMITTER:-}" ]; then
  note "deploying the cctp adapter"
  CCTP=$(reuse_or_deploy HYPERION_CCTP_ADAPTER "$CCTP_HASH" "cctp adapter")
  say "cctp adapter     $CCTP"
  if is_initialized "$CCTP"; then
    say "already initialized, leaving it alone"
  else
  invoke "$CCTP" initialize \
    --admin "$DEPLOYER" \
    --router "$ROUTER" \
    --token_messenger "$CCTP_TOKEN_MESSENGER" \
    --message_transmitter "$CCTP_MESSAGE_TRANSMITTER" >/dev/null || die "cctp initialize"
  fi

  say "deployed and initialized, not yet linked to a peer"
else
  note "skipping the cctp adapter"
  say "CCTP_TOKEN_MESSENGER and CCTP_MESSAGE_TRANSMITTER are not set."
  say "Circle deploys these from circlefin/stellar-cctp and does not publish a fixed"
  say "address list, so there is nothing safe to default to. The router deploys without"
  say "it and refuses CCTP transfers with AdapterNotSet, which is the correct answer."
fi

AXELAR=""
if [ -n "${AXELAR_ITS:-}" ]; then
  note "deploying the axelar adapter"
  AXELAR=$(reuse_or_deploy HYPERION_AXELAR_ADAPTER "$AXELAR_HASH" "axelar adapter")
  say "axelar adapter   $AXELAR"
  if is_initialized "$AXELAR"; then
    say "already initialized, leaving it alone"
  else
  invoke "$AXELAR" initialize \
    --admin "$DEPLOYER" \
    --router "$ROUTER" \
    --its "$AXELAR_ITS" \
    --route "$ROUTE_AXELAR_ITS" >/dev/null || die "axelar initialize"
  fi

  say "deployed and initialized, not yet linked to a peer"
else
  note "skipping the axelar adapter"
  say "AXELAR_ITS is not set. Axelar publishes its Stellar contracts in"
  say "axelar-chains-config/info, so this one does have a safe value to pass."
fi

# ---------------------------------------------------------------------------------------------
# The router's own configuration, all of it on a clock.
# ---------------------------------------------------------------------------------------------

QUEUE_IDS=()
QUEUE_WHAT=()

# Everything already waiting on the router's clock, as a JSON array of {id, action}.
#
# Read once, so re-running this script does not queue a second copy of a change that is already
# pending. The first draft did, and three runs left six queued actions where four were wanted.
# Duplicates are not dangerous here, since every one of these is idempotent when applied, but a
# timelock only does its job if a reviewer can read the pending list and recognise it.
PENDING_FILE=$(mktemp)
trap 'rm -f "$PENDING_FILE"' EXIT

load_pending() {
  local count
  count=$(read_only "$ROUTER" queue_count | tr -d '"[:space:]')
  [ -n "$count" ] || count=0
  printf '[' > "$PENDING_FILE"
  local first=1 i entry
  for i in $(seq 1 "$count"); do
    # A queued action that has already been executed or cancelled is gone from storage, so a
    # failed read means there is nothing pending under that id.
    entry=$(read_only "$ROUTER" get_queued --id "$i" 2>/dev/null) || continue
    [ -n "$entry" ] || continue
    [ "$first" -eq 1 ] || printf ',' >> "$PENDING_FILE"
    printf '%s' "$entry" >> "$PENDING_FILE"
    first=0
  done
  printf ']' >> "$PENDING_FILE"
  say "$count action(s) have been queued on this router at some point"
}

# The id of a pending action identical to the one given, or empty.
#
# Compares the canonical JSON form of both sides rather than the text, so field order and
# whitespace cannot produce a false mismatch.
pending_id_for() {
  node -e '
const fs = require("fs");
const canon = (v) => {
  if (Array.isArray(v)) return v.map(canon);
  if (v && typeof v === "object") {
    return Object.fromEntries(Object.keys(v).sort().map((k) => [k, canon(v[k])]));
  }
  // The CLI prints an i128 as a string and takes it as a string, but a u32 comes back as a
  // number. Comparing the printed forms sidesteps having to know which is which.
  return typeof v === "number" ? String(v) : v;
};
const key = (v) => JSON.stringify(canon(v));
const want = key(JSON.parse(process.argv[2]));
const pending = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const hit = pending.find((q) => q && q.action !== undefined && key(q.action) === want);
process.stdout.write(hit ? String(hit.id) : "");
' "$PENDING_FILE" "$1" 2>/dev/null
}

queue() {
  local what="$1" action="$2"
  local id errfile

  id=$(pending_id_for "$action")
  if [ -n "$id" ]; then
    say "pending already $id  $what"
    QUEUE_IDS+=("$id")
    QUEUE_WHAT+=("$what")
    return
  fi

  errfile=$(mktemp)
  if ! id=$(invoke "$ROUTER" queue_action --caller "$DEPLOYER" --action "$action" 2>"$errfile"); then
    # The reason a queue was refused is the single most useful thing on screen at this moment,
    # and the first draft of this function threw it away with 2>/dev/null.
    printf '\n' >&2
    tail -12 "$errfile" >&2
    rm -f "$errfile"
    die "queue_action for \"$what\" was refused. The action was: $action"
  fi
  rm -f "$errfile"

  id=$(printf '%s' "$id" | tr -d '"[:space:]')
  [ -n "$id" ] || die "queue_action for \"$what\" returned no id"
  QUEUE_IDS+=("$id")
  QUEUE_WHAT+=("$what")
  say "queued $id  $what"
}

note "queueing the router configuration"
load_pending
queue "register $ASSET_CODE" "{\"RegisterToken\":[\"$SAC\",7,\"$FLOW_LIMIT\"]}"

if [ -n "$CCTP" ]; then
  queue "set cctp adapter"  "{\"SetAdapter\":[$ROUTE_CCTP,\"$CCTP\"]}"
  queue "set cctp receiver" "{\"SetRailReceiver\":[$ROUTE_CCTP,\"$CCTP\"]}"
  queue "enable cctp"       "{\"EnableRoute\":$ROUTE_CCTP}"
fi

if [ -n "$AXELAR" ]; then
  queue "set axelar adapter"  "{\"SetAdapter\":[$ROUTE_AXELAR_ITS,\"$AXELAR\"]}"
  queue "set axelar receiver" "{\"SetRailReceiver\":[$ROUTE_AXELAR_ITS,\"$AXELAR\"]}"
  queue "enable axelar its"   "{\"EnableRoute\":$ROUTE_AXELAR_ITS}"
fi

# Last, and only when the admin is somebody else. An admin change that landed first would leave
# every action after it queued by an account that can no longer execute anything.
if [ "$ADMIN" != "$DEPLOYER" ]; then
  queue "hand admin to the real holder" "{\"SetAdmin\":\"$ADMIN\"}"
fi

note "writing the record"
mkdir -p "$RECORD_DIR"
ROUTER_LEDGER="${ROUTER_LEDGER:-${STELLAR_START_LEDGER:-${HYPERION_ROUTER_LEDGER:-}}}"
RECORD="$RECORD_DIR/stellar-$NETWORK-phase1.json"

IDS_JSON=$(printf '%s\n' "${QUEUE_IDS[@]}" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.stringify(s.trim().split("\n").filter(Boolean).map(Number))))')
WHAT_JSON=$(printf '%s\n' "${QUEUE_WHAT[@]}" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.stringify(s.trim().split("\n").filter(Boolean))))')

STELLAR_NETWORK="$NETWORK" \
HYPERION_ROUTER="$ROUTER" \
HYPERION_ROUTER_LEDGER="$ROUTER_LEDGER" \
HYPERION_CCTP="$CCTP" \
HYPERION_AXELAR="$AXELAR" \
HYPERION_SAC="$SAC" \
HYPERION_ASSET_CODE="$ASSET_CODE" \
HYPERION_ASSET="$ASSET" \
HYPERION_DEPLOYER="$DEPLOYER" \
HYPERION_ADMIN="$ADMIN" \
HYPERION_GUARDIAN="$GUARDIAN" \
HYPERION_TREASURY="$TREASURY" \
HYPERION_FEE_BPS="$FEE_BPS" \
HYPERION_FLOW_WINDOW_LEDGERS="$FLOW_WINDOW" \
HYPERION_TIMELOCK_DELAY="$TIMELOCK" \
HYPERION_TOKEN_FLOW_LIMIT="$FLOW_LIMIT" \
HYPERION_PEER_CHAIN="$PEER" \
ROUTER_HASH="$ROUTER_HASH" CCTP_HASH="$CCTP_HASH" AXELAR_HASH="$AXELAR_HASH" \
QUEUE_IDS_JSON="$IDS_JSON" QUEUE_WHAT_JSON="$WHAT_JSON" \
node "$(dirname "${BASH_SOURCE[0]}")/write-record.mjs" "$RECORD" || die "writing the record"
say "$RECORD"

note "phase one is done"
say "Nothing is routable yet, and two separate things are still missing."
say ""
say "Queued actions   ${#QUEUE_IDS[@]}"
say "Earliest execution is $TIMELOCK seconds from the ledger that queued them."
say ""
say "Read them off the chain before you execute them:"
say "  stellar contract invoke --id $ROUTER --network $NETWORK -- get_queued --id ${QUEUE_IDS[0]:-1}"
say ""
say "Then, in either order:"
say "  script/stellar/execute.sh   once the timelock has matured"
say "  script/stellar/link.sh      once Hyperion exists on $PEER"
say ""
say "The adapters are deployed and initialized but linked to nothing. That is not an"
say "oversight: a peer cannot be named before it exists, and both link setters are once"
say "only, so a guessed address is a mistake no transaction can undo. Deploy the far"
say "side first, then link."
