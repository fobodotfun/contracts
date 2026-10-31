#!/usr/bin/env bash
# Rehearses the governance change on a fork of Robinhood Chain mainnet, end to end, before the Owner Safe signs anything:
#   1. anvil forks mainnet on port 8585 and the Safe is impersonated (anvil_impersonateAccount + a balance)
#   2. script/Govern.s.sol deploys the TimelockController and FoboQuoteGate on the fork (from anvil's first account, as
#      a deployer key would) and prints the Safe transactions; this script sends each one from the Safe, in order, in
#      one sitting (the timelock starts at delay 0 and raises it to 48 h itself at the end)
#   3. every quote the factory allows today, ETH and $FOBO aside, goes through the gate as it would for real: the Safe
#      (the gate's owner) is given one whole unit of it on the fork, approves the gate and probes; PROBE_BLOCKS are
#      mined; the Safe allows. A table per quote says how far it got and why it stopped
#   4. the end state is checked: burner.owner() == timelock, factory.owner() == gate, gate.owner() == Safe, the
#      timelock's delay is 48 h, emergencyWithdraw straight from the Safe reverts, setLaunchesPaused through the gate
#      from the Safe takes effect at once, and FoboLimitOrders.ethUsd() reads Chainlink's answer unchanged through the
#      bounded feed
# How a quote is funded: its balances mapping is found by trying storage slots 0..30 and the ERC-7201 ERC20 slot for
# the Safe's key (anvil_setStorageAt, undone when the balance doesn't read back); failing that, the PoolManager
# (every FOBO pool's reserve) is impersonated and transfers it. The table says which. Nothing here touches mainnet:
# the upstream RPC is only read. Never pass --broadcast against anything but this fork.
#   FORK_RPC_URL          the mainnet RPC to fork (default: Robinhood Chain's public one, which keeps state ~10 minutes)
#   FORK_ARCHIVE_RPC_URL  a public archive RPC for the state it has pruned (default: https://robinhood.drpc.org); anvil
#                         forks through script/fork-rpc.mjs, which asks the archive only what the first can't answer (a run
#                         outlasts the public RPC's state window). Both keyless, like the site's local stack: never a keyed
#                         provider, its key would sit in anvil's arguments and logs
#   SAFE, FACTORY, BURNER  default to the mainnet deployment (deployments/robinhood.json)
set -euo pipefail
cd "$(dirname "$0")/.."

UPSTREAM=${FORK_RPC_URL:-https://rpc.mainnet.chain.robinhood.com}
ARCHIVE=${FORK_ARCHIVE_RPC_URL:-https://robinhood.drpc.org}
for url in "$UPSTREAM" "$ARCHIVE"; do
    case "$url" in *alchemy* | *infura* | *quicknode* | *\?* | */v2/*) echo "fork RPCs must be public, without a key: $url" >&2; exit 1 ;; esac
done
PORT=8585
FORK_RPC_PORT=8586 # local/fork-rpc.mjs, anvil's upstream
RPC=http://127.0.0.1:$PORT
CHAIN_ID=4663
SAFE=${SAFE:-0xC631717e01Add467E9ce96f8cA5E09f0dB37386A}
FACTORY=${FACTORY:-0xd7e538e98A208fD19e46bc549FF4710C33664e18}
BURNER=${BURNER:-0x5541141CC427441F7eD5BD93Bd16AC87a890990d}
LIMIT_ORDERS=${LIMIT_ORDERS:-0x3126f62d604a0AA2de8788e3eC21dDd8F2a2f82a}
POOL_MANAGER=0x8366a39CC670B4001A1121B8F6A443A643e40951
FACTORY_START_BLOCK=98531915
DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 # anvil's first account
DELAY=172800 # Govern.MIN_DELAY, 48 h: what the timelock's delay must be at the end
ZERO32=0x0000000000000000000000000000000000000000000000000000000000000000
# OpenZeppelin's ERC-7201 slot of ERC20Upgradeable's storage (its balances mapping comes first):
# keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ERC20")) - 1)) & ~0xff
ERC7201_ERC20=$(python3 -c "print(hex(int('$(cast keccak "$(cast to-uint256 "$(python3 -c "print(int('$(cast keccak openzeppelin.storage.ERC20)', 16) - 1)")")")', 16) & ~0xff))")

for p in $PORT $FORK_RPC_PORT; do
    if lsof -nP -iTCP:$p -sTCP:LISTEN >/dev/null 2>&1; then
        echo "port $p is in use" >&2
        exit 1
    fi
done
BROADCAST_DIR=$(mktemp -d)
# the public RPC drops requests now and then: anvil gives up on one fast (else a dropped fetch stalls every call behind
# it past cast's own 45 s limit) and every read and send below is retried
node "$(dirname "$0")/fork-rpc.mjs" $FORK_RPC_PORT "$UPSTREAM" "$ARCHIVE" >/dev/null &
RELAY=$!
trap 'kill $RELAY 2>/dev/null || true; rm -rf "$BROADCAST_DIR"' EXIT
for _ in $(seq 1 30); do
    nc -z 127.0.0.1 $FORK_RPC_PORT 2>/dev/null && break
    sleep 1
done
nc -z 127.0.0.1 $FORK_RPC_PORT 2>/dev/null || { echo "fork-rpc relay did not come up" >&2; exit 1; }
# --prune-history: anvil keeps every block's full state in memory by default, and the probe stage mines PROBE_BLOCKS of
# them (a run passed 3 GB and the Mac's memory guard killed it); nothing here reads anvil at an old block
anvil --fork-url http://127.0.0.1:$FORK_RPC_PORT --chain-id $CHAIN_ID --port $PORT --silent --timeout 15000 --retries 2 \
    --prune-history &
ANVIL=$!
trap 'kill $ANVIL $RELAY 2>/dev/null || true; rm -rf "$BROADCAST_DIR"' EXIT
for _ in $(seq 1 60); do
    cast chain-id --rpc-url $RPC >/dev/null 2>&1 && break
    sleep 1
done
[ "$(cast chain-id --rpc-url $RPC)" = "$CHAIN_ID" ] || { echo "anvil did not come up" >&2; exit 1; }

# reads and anvil RPCs, retried: a fork call that needs upstream state can time out on the public RPC
retry() {
    local n
    for n in 1 2 3 4 5; do
        if "$@"; then return 0; fi
        sleep 2
    done
    return 1
}
rpc() { retry cast rpc --rpc-url $RPC "$@" >/dev/null; }
call() { retry cast call --rpc-url $RPC "$@"; }
storage() { retry cast storage --rpc-url $RPC "$@"; }
num() { awk '{print $1}'; } # cast's "123 [1.23e2]" to 123
# cast send from an impersonated account; on a revert, REASON holds the decoded error and the status is 1. An RPC
# error that is not a revert (upstream dropped a fetch) is retried; the send itself was never made then
REASON=
send() {
    local from=$1
    shift
    local out n
    for n in 1 2 3 4 5; do
        if out=$(cast send --rpc-url $RPC --unlocked --from "$from" "$@" 2>&1); then
            REASON=
            return 0
        fi
        if grep -qi "revert" <<<"$out"; then
            REASON=$(decode_revert "$out")
            return 1
        fi
        sleep 3
    done
    REASON="rpc error: $(tail -1 <<<"$out")"
    return 1
}
# the first revert payload in cast's error text, as the gate's (or OpenZeppelin's) error name
decode_revert() {
    local data sel
    data=$(grep -oE '0x[0-9a-fA-F]{8,}' <<<"$1" | head -1 || true)
    [ -n "$data" ] || { echo "reverted (no data)"; return; }
    sel=${data:0:10}
    case $sel in
    "$(cast sig 'ProbeMismatch(uint256,uint256)')") echo "ProbeMismatch $(cast abi-decode 'f()(uint256,uint256)' "0x${data:10}" | num | tr '\n' ' ')" ;;
    "$(cast sig 'Reentered()')") echo "Reentered" ;;
    "$(cast sig 'NoProbeForThis()')") echo "NoProbeForThis" ;;
    "$(cast sig 'NotProbed()')") echo "NotProbed" ;;
    "$(cast sig 'ProbeTooFresh(uint256)')") echo "ProbeTooFresh" ;;
    "$(cast sig 'SampleDrifted(uint256,uint256)')") echo "SampleDrifted $(cast abi-decode 'f()(uint256,uint256)' "0x${data:10}" | num | tr '\n' ' ')" ;;
    "$(cast sig 'SampleHeld()')") echo "SampleHeld" ;;
    "$(cast sig 'OwnableUnauthorizedAccount(address)')") echo "OwnableUnauthorizedAccount" ;;
    "$(cast sig 'TimelockUnexpectedOperationState(bytes32,bytes32)')") echo "TimelockUnexpectedOperationState" ;;
    "$(cast sig 'FailedInnerCall()')") echo "FailedInnerCall (the target reverted without data)" ;;
    "$(cast sig 'Error(string)')") echo "Error: $(cast abi-decode 'f()(string)' "0x${data:10}")" ;;
    *) echo "$sel" ;;
    esac
}
# mines $1 blocks in chunks of 720: anvil mines them one by one, a long run outlasts cast's 45 s request limit
mine() {
    local left=$1 n
    while [ "$left" -gt 0 ]; do
        n=$((left > 720 ? 720 : left))
        curl -s --max-time 600 -X POST -H 'content-type: application/json' \
            --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"anvil_mine\",\"params\":[\"$(cast to-hex $n)\"]}" $RPC >/dev/null
        left=$((left - n))
    done
}

echo "== fork of $UPSTREAM (archive $ARCHIVE) at block $(cast block-number --rpc-url $RPC) on $RPC"
rpc anvil_impersonateAccount "$SAFE"
rpc anvil_setBalance "$SAFE" 0x3635C9ADC5DEA00000 # 1000 ETH
[ "$(call "$FACTORY" 'owner()(address)')" = "$SAFE" ] || { echo "the Safe does not own the factory" >&2; exit 1; }
[ "$(call "$BURNER" 'owner()(address)')" = "$SAFE" ] || { echo "the Safe does not own the burner" >&2; exit 1; }
[ "$(call "$LIMIT_ORDERS" 'owner()(address)')" = "$SAFE" ] || { echo "the Safe does not own the limit orders" >&2; exit 1; }
ETH_USD_BEFORE=$(call "$LIMIT_ORDERS" 'ethUsd()(uint256)' | num)
# the Chainlink feed ETH is priced by before the switch: the bounded feed must forward exactly this one
ETH_FEED_BEFORE=$(call "$LIMIT_ORDERS" 'payTokens(address)((address,uint40,uint8,uint8,bool),bool)' 0x0000000000000000000000000000000000000000 | head -1 | cut -d'(' -f2 | cut -d, -f1)

echo "== Govern.s.sol: deploy the timelock and the gate, print the Safe transactions"
OUT=$(SAFE=$SAFE FACTORY=$FACTORY BURNER=$BURNER LIMIT_ORDERS=$LIMIT_ORDERS FOUNDRY_BROADCAST=$BROADCAST_DIR \
    forge script script/Govern.s.sol --rpc-url $RPC --broadcast --unlocked --sender $DEPLOYER 2>&1) || {
    echo "$OUT"
    exit 1
}
sed -n '/== Logs ==/,/^== /p' <<<"$OUT" | grep -v "^== \|GOVERN" | sed 's/^  //; s/^SAFE_TX [0-9]* /   to: /; s/ 0x/  data: 0x/2'
TIMELOCK=$(grep -oE 'GOVERN timelock=0x[0-9a-fA-F]{40}' <<<"$OUT" | cut -d= -f2)
GATE=$(grep -oE 'gate=0x[0-9a-fA-F]{40}' <<<"$OUT" | cut -d= -f2)
FEED=$(grep -oE 'feed=0x[0-9a-fA-F]{40}' <<<"$OUT" | cut -d= -f2)
[ -n "$TIMELOCK" ] && [ -n "$GATE" ] && [ -n "$FEED" ] || { echo "no GOVERN line in the script output" >&2; exit 1; }
PROBE_BLOCKS=$(call "$GATE" 'PROBE_BLOCKS()(uint256)' | num)

echo "== the Safe sends them"
send_safe_tx() {
    local n=$1 to data
    read -r to data < <(grep -oE "SAFE_TX $n 0x[0-9a-fA-F]{40} 0x[0-9a-fA-F]+" <<<"$OUT" | awk '{print $3, $4}')
    [ -n "$to" ] || { echo "SAFE_TX $n missing" >&2; exit 1; }
    if send "$SAFE" "$to" "$data"; then
        echo "  $n) ok   -> $to"
    else
        echo "  $n) FAIL -> $to: $REASON"
        exit 1
    fi
}
for n in 1 2 3 4 5 6 7 8; do send_safe_tx $n; done

echo "== every allowed quote through the gate (probe, $PROBE_BLOCKS blocks, allow), from the Safe"
QUOTES=$(cast logs --rpc-url "$UPSTREAM" --from-block $FACTORY_START_BLOCK --to-block latest --address "$FACTORY" \
    'QuoteAllowed(address indexed quote, bool allowed)' --json |
    python3 -c '
import json, sys
state = {}
for log in json.load(sys.stdin):
    quote = "0x" + log["topics"][1][-40:]
    state[quote] = int(log["data"], 16) == 1
print("\n".join(q for q, on in state.items() if on))')
FOBO=$(call "$FACTORY" 'fobo()(address)' | tr 'A-F' 'a-f')
APPROVE_SEL='approve(address,uint256)'
ROWS=()
for q in $QUOTES; do
    [ "$q" = "0x0000000000000000000000000000000000000000" ] && continue
    [ "$q" = "$FOBO" ] && continue
    [ "$(call "$FACTORY" 'quotes(address)(bool,int24,int24,uint8)' "$q" | head -1)" = "true" ] || continue
    symbol=$(call "$q" 'symbol()(string)' 2>/dev/null | tr -d '"' || echo "?")
    decimals=$(call "$q" 'decimals()(uint8)' 2>/dev/null | num || echo 18)
    amount=$(python3 -c "print(10 ** $decimals)")
    amount32=$(cast to-uint256 "$amount")

    # fund the Safe: the balances slot, else the PoolManager's reserve
    funded=
    for i in $(seq 0 30) "$ERC7201_ERC20"; do
        slot=$(cast index address "$SAFE" "$i")
        orig=$(storage "$q" "$slot")
        rpc anvil_setStorageAt "$q" "$slot" "$amount32"
        if [ "$(call "$q" 'balanceOf(address)(uint256)' "$SAFE" | num)" = "$amount" ]; then
            funded=$([ "$i" = "$ERC7201_ERC20" ] && echo "ERC-7201 ERC20 slot" || echo "slot $i")
            break
        fi
        rpc anvil_setStorageAt "$q" "$slot" "$orig"
    done
    if [ -z "$funded" ]; then
        pmBal=$(call "$q" 'balanceOf(address)(uint256)' "$POOL_MANAGER" | num)
        if [ "$(python3 -c "print(int('$pmBal') >= $amount)")" = "True" ]; then
            rpc anvil_impersonateAccount $POOL_MANAGER
            rpc anvil_setBalance $POOL_MANAGER 0xDE0B6B3A7640000
            if send $POOL_MANAGER "$q" 'transfer(address,uint256)' "$SAFE" "$amount"; then
                funded="PoolManager transfer"
            fi
        fi
    fi
    if [ -z "$funded" ]; then
        ROWS+=("$symbol|$q|not run (could not fund)|not run|-")
        continue
    fi

    # the Safe approves the gate and probes
    send "$SAFE" "$q" "$APPROVE_SEL" "$GATE" "$amount" || { echo "approve: $REASON" >&2; exit 1; }
    if send "$SAFE" "$GATE" 'probe(address,uint256)' "$q" "$amount"; then
        probeResult="ok"
    else
        ROWS+=("$symbol|$q|FAIL ($REASON)|not run|$funded")
        continue
    fi
    mine "$PROBE_BLOCKS"
    if send "$SAFE" "$GATE" 'allow(address)' "$q"; then
        allowResult="ok"
    else
        allowResult="FAIL ($REASON)"
    fi
    ROWS+=("$symbol|$q|$probeResult|$allowResult|$funded")
done
printf '\n%-8s %-44s %-28s %-28s %s\n' symbol address probe allow funded
for row in "${ROWS[@]}"; do
    IFS='|' read -r s a p l f <<<"$row"
    printf '%-8s %-44s %-28s %-28s %s\n' "$s" "$a" "$p" "$l" "$f"
done

echo
echo "== end state"
check() { # what, got, want
    if [ "$(tr 'A-F' 'a-f' <<<"$2")" = "$(tr 'A-F' 'a-f' <<<"$3")" ]; then echo "  ok   $1 = $2"; else
        echo "  FAIL $1 = $2, wanted $3"
        FAILED=1
    fi
}
FAILED=
check "burner.owner()" "$(call "$BURNER" 'owner()(address)')" "$TIMELOCK"
check "factory.owner()" "$(call "$FACTORY" 'owner()(address)')" "$GATE"
check "gate.owner()" "$(call "$GATE" 'owner()(address)')" "$SAFE"
check "timelock.getMinDelay()" "$(call "$TIMELOCK" 'getMinDelay()(uint256)' | num)" "$DELAY"
check "limitOrders ETH feed" "$(call "$LIMIT_ORDERS" 'payTokens(address)((address,uint40,uint8,uint8,bool),bool)' 0x0000000000000000000000000000000000000000 | head -1 | cut -d'(' -f2 | cut -d, -f1)" "$FEED"
check "limitOrders.ethUsd() through the bounded feed" "$(call "$LIMIT_ORDERS" 'ethUsd()(uint256)' | num)" "$ETH_USD_BEFORE"
check "bounded feed source" "$(call "$FEED" 'source()(address)')" "$ETH_FEED_BEFORE"
check "Safe is proposer" "$(call "$TIMELOCK" 'hasRole(bytes32,address)(bool)' "$(call "$TIMELOCK" 'PROPOSER_ROLE()(bytes32)')" "$SAFE")" true
check "Safe is executor" "$(call "$TIMELOCK" 'hasRole(bytes32,address)(bool)' "$(call "$TIMELOCK" 'EXECUTOR_ROLE()(bytes32)')" "$SAFE")" true
check "Safe is not admin" "$(call "$TIMELOCK" 'hasRole(bytes32,address)(bool)' $ZERO32 "$SAFE")" false
if send "$SAFE" "$BURNER" 'emergencyWithdraw(address,address)' 0x0000000000000000000000000000000000000000 "$SAFE"; then
    echo "  FAIL emergencyWithdraw from the Safe went through"
    FAILED=1
else
    check "emergencyWithdraw from the Safe" "$REASON" "OwnableUnauthorizedAccount"
fi
if send "$SAFE" "$FACTORY" 'setQuoteAllowed(address,bool)' 0x0000000000000000000000000000000000000000 true; then
    echo "  FAIL setQuoteAllowed on the factory from the Safe went through"
    FAILED=1
else
    check "setQuoteAllowed on the factory from the Safe" "$REASON" "OwnableUnauthorizedAccount"
fi
# the Safe pauses launches through the gate with no delay, and unpauses them
if send "$SAFE" "$GATE" 'setLaunchesPaused(bool)' true; then
    check "setLaunchesPaused(true) through the gate, at once" "$(call "$FACTORY" 'launchesPaused()(bool)')" true
    send "$SAFE" "$GATE" 'setLaunchesPaused(bool)' false || { echo "  FAIL unpause: $REASON"; FAILED=1; }
    check "setLaunchesPaused(false) through the gate" "$(call "$FACTORY" 'launchesPaused()(bool)')" false
else
    echo "  FAIL setLaunchesPaused through the gate from the Safe: $REASON"
    FAILED=1
fi
[ -z "$FAILED" ] && echo "rehearsal passed" || { echo "rehearsal FAILED" >&2; exit 1; }
