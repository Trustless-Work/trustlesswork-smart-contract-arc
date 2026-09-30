#!/usr/bin/env bash
# End-to-end happy path on a live network (Arc testnet by default):
# create (two milestones, two receivers) -> fund -> change status ->
# approve & release each milestone on its own.
#
# Arc's USDC runs on node-level precompiles that Foundry cannot simulate, so
# this uses plain `cast send` transactions instead of a `forge script`.
#
#   PRIVATE_KEY=0x... ./script/e2e.sh                 # deploys library + factory
#   PRIVATE_KEY=0x... FACTORY=0x... ./script/e2e.sh   # reuses a factory
#
# PRIVATE_KEY needs ~1.5 USDC on Arc testnet (https://faucet.circle.com). It acts
# as factory owner, fee recipient, admin, platform and funder. Role keys
# (approver+release signer, provider, resolver) are derived from it; the
# second milestone pays a derived address that never signs.
set -euo pipefail

RPC_URL="${RPC_URL:-https://rpc.testnet.arc.io}"
USDC="${USDC:-0x3600000000000000000000000000000000000000}"
: "${PRIVATE_KEY:?set PRIVATE_KEY}"
cd "$(dirname "$0")/.."

derive() { cast keccak "$(cast abi-encode 'f(uint256,string)' "$PRIVATE_KEY" "$1")"; }
send() { cast send --rpc-url "$RPC_URL" --private-key "$1" "${@:2}" >/dev/null; }
call() { cast call --rpc-url "$RPC_URL" "$@"; }
bal() { call "$USDC" "balanceOf(address)(uint256)" "$1" | awk '{print $1}'; }
deploy() { forge create --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast "$@" | awk '/Deployed to:/ {print $3}'; }

DEPLOYER=$(cast wallet address "$PRIVATE_KEY")
APPROVER_PK=$(derive approver); APPROVER=$(cast wallet address "$APPROVER_PK")
PROVIDER_PK=$(derive provider); PROVIDER=$(cast wallet address "$PROVIDER_PK")
RESOLVER=$(cast wallet address "$(derive resolver)")
RECEIVER2=$(cast wallet address "$(derive receiver2)")
echo "deployer=$DEPLOYER approver=$APPROVER provider=$PROVIDER resolver=$RESOLVER receiver2=$RECEIVER2"

if [[ -z "${FACTORY:-}" ]]; then
  # The escrow calls its validation library with DELEGATECALL: deploy it
  # first and link it into the factory (which embeds the escrow bytecode).
  LIBRARY=$(deploy src/libraries/MultiReleaseValidation.sol:MultiReleaseValidation)
  echo "library=$LIBRARY"
  FACTORY=$(deploy src/MultiReleaseEscrowFactory.sol:MultiReleaseEscrowFactory \
    --libraries "src/libraries/MultiReleaseValidation.sol:MultiReleaseValidation:$LIBRARY" \
    --constructor-args "$DEPLOYER" "$DEPLOYER")
fi
echo "factory=$FACTORY"

# Gas for the two role keys that send transactions (native value = USDC on Arc).
send "$PRIVATE_KEY" "$APPROVER" --value 0.1ether
send "$PRIVATE_KEY" "$PROVIDER" --value 0.1ether

SALT=$(cast keccak "e2e-$(date +%s)")
ESCROW=$(call "$FACTORY" "predictEscrowAddress(address,bytes32)(address)" "$DEPLOYER" "$SALT")
ROLES_T='(address[],address[],address,address[],address[],address,address[])'
MILESTONE_T='(string,string,string,(uint32,uint32,address[]),uint256,(bool,string,bool),bool,address)'
ESCROW_T="(string,string,$ROLES_T,string,uint32,$MILESTONE_T[],address,uint32)"
MS0="(\"Design\",\"Pending\",\"\",(1,0,[]),600000,(false,\"\",false),false,$PROVIDER)"
MS1="(\"Build\",\"Pending\",\"\",(1,0,[]),400000,(false,\"\",false),false,$RECEIVER2)"
PROPS="(\"E2E-$SALT\",\"Arc E2E\",([$APPROVER],[$PROVIDER],$DEPLOYER,[$APPROVER],[$RESOLVER],$DEPLOYER,[]),\"Arc end-to-end\",500,[$MS0,$MS1],$USDC,0)"
send "$PRIVATE_KEY" "$FACTORY" "createEscrow(bytes32,$ESCROW_T)" "$SALT" "$PROPS"
echo "escrow=$ESCROW"

HASH=$(call "$ESCROW" "escrowHash()(bytes32)")
send "$PRIVATE_KEY" "$USDC" "approve(address,uint256)" "$ESCROW" 1000000
send "$PRIVATE_KEY" "$ESCROW" "fundEscrow(uint256,bytes32)" 1000000 "$HASH"
echo "funded: escrow balance=$(bal "$ESCROW")"

send "$PROVIDER_PK" "$ESCROW" "changeMilestoneStatus((uint32,string,bool,string)[])" '[(0,"Done",true,"ipfs://proof")]'
# Snapshot after the provider's last tx: on Arc gas is paid from the same USDC balance.
PROVIDER_BEFORE=$(bal "$PROVIDER")

send "$APPROVER_PK" "$ESCROW" "approveAndReleaseMilestones(uint32[])" '[0]'
AFTER_FIRST=$(bal "$ESCROW")
send "$APPROVER_PK" "$ESCROW" "approveAndReleaseMilestones(uint32[])" '[1]'

GOT0=$(( $(bal "$PROVIDER") - PROVIDER_BEFORE ))
GOT1=$(bal "$RECEIVER2")
LEFT=$(bal "$ESCROW")
echo "milestone 0 -> provider got $GOT0 (expected 568200); escrow left $AFTER_FIRST (expected 400000)"
echo "milestone 1 -> receiver2 got $GOT1 (expected 378800); escrow left $LEFT (expected 0)"
[[ "$GOT0" == "568200" && "$AFTER_FIRST" == "400000" && "$GOT1" == "378800" && "$LEFT" == "0" ]] \
  && echo "E2E OK" || { echo "E2E FAILED"; exit 1; }
