#!/usr/bin/env bash
# End-to-end happy path on a live network (Arc testnet by default):
# create -> fund -> change milestone status -> approve & release.
#
# Arc's USDC runs on node-level precompiles that Foundry cannot simulate, so
# this uses plain `cast send` transactions instead of a `forge script`.
#
#   PRIVATE_KEY=0x... ./script/e2e.sh                 # deploys a fresh factory
#   PRIVATE_KEY=0x... FACTORY=0x... ./script/e2e.sh   # reuses a factory
#
# PRIVATE_KEY needs ~1.5 USDC on Arc testnet (https://faucet.circle.com). It acts
# as factory owner, fee recipient, admin, platform and funder. Three role keys
# (approver+release signer, provider+receiver, resolver) are derived from it.
set -euo pipefail

RPC_URL="${RPC_URL:-https://rpc.testnet.arc.io}"
USDC="${USDC:-0x3600000000000000000000000000000000000000}"
: "${PRIVATE_KEY:?set PRIVATE_KEY}"
cd "$(dirname "$0")/.."

derive() { cast keccak "$(cast abi-encode 'f(uint256,string)' "$PRIVATE_KEY" "$1")"; }
send() { cast send --rpc-url "$RPC_URL" --private-key "$1" "${@:2}" >/dev/null; }
call() { cast call --rpc-url "$RPC_URL" "$@"; }
bal() { call "$USDC" "balanceOf(address)(uint256)" "$1" | awk '{print $1}'; }

DEPLOYER=$(cast wallet address "$PRIVATE_KEY")
APPROVER_PK=$(derive approver); APPROVER=$(cast wallet address "$APPROVER_PK")
PROVIDER_PK=$(derive provider); PROVIDER=$(cast wallet address "$PROVIDER_PK")
RESOLVER=$(cast wallet address "$(derive resolver)")
echo "deployer=$DEPLOYER approver=$APPROVER provider=$PROVIDER resolver=$RESOLVER"

if [[ -z "${FACTORY:-}" ]]; then
  FACTORY=$(forge create src/SingleReleaseEscrowFactory.sol:SingleReleaseEscrowFactory \
    --rpc-url "$RPC_URL" --private-key "$PRIVATE_KEY" --broadcast \
    --constructor-args "$DEPLOYER" "$DEPLOYER" | awk '/Deployed to:/ {print $3}')
fi
echo "factory=$FACTORY"

# Gas for the two role keys that send transactions (native value = USDC on Arc).
send "$PRIVATE_KEY" "$APPROVER" --value 0.1ether
send "$PRIVATE_KEY" "$PROVIDER" --value 0.1ether

SALT=$(cast keccak "e2e-$(date +%s)")
ESCROW=$(call "$FACTORY" "predictEscrowAddress(address,bytes32)(address)" "$DEPLOYER" "$SALT")
ESCROW_T='(string,string,(address[],address[],address,address[],address[],address,address,address[]),string,uint256,uint32,(string,string,string,(uint32,uint32,address[]))[],(bool,string,bool),bool,address,uint32)'
PROPS="(\"E2E-$SALT\",\"Arc E2E\",([$APPROVER],[$PROVIDER],$DEPLOYER,[$APPROVER],[$RESOLVER],$PROVIDER,$DEPLOYER,[]),\"Arc end-to-end\",1000000,500,[(\"Deliver\",\"Pending\",\"\",(1,0,[]))],(false,\"\",false),false,$USDC,0)"
send "$PRIVATE_KEY" "$FACTORY" "createEscrow(bytes32,$ESCROW_T)" "$SALT" "$PROPS"
echo "escrow=$ESCROW"

HASH=$(call "$ESCROW" "escrowHash()(bytes32)")
send "$PRIVATE_KEY" "$USDC" "approve(address,uint256)" "$ESCROW" 1000000
send "$PRIVATE_KEY" "$ESCROW" "fundEscrow(uint256,bytes32)" 1000000 "$HASH"
echo "funded: escrow balance=$(bal "$ESCROW")"

send "$PROVIDER_PK" "$ESCROW" "changeMilestoneStatus((uint32,string,bool,string)[])" '[(0,"Done",true,"ipfs://proof")]'
# Snapshot after the provider's last tx: on Arc gas is paid from the same USDC balance.
RECEIVER_BEFORE=$(bal "$PROVIDER")
send "$APPROVER_PK" "$ESCROW" "approveAndReleaseMilestones(uint32[])" '[0]'

ESCROW_AFTER=$(bal "$ESCROW")
RECEIVED=$(( $(bal "$PROVIDER") - RECEIVER_BEFORE ))
echo "released: receiver got $RECEIVED (expected 947000), escrow balance=$ESCROW_AFTER"
[[ "$RECEIVED" == "947000" && "$ESCROW_AFTER" == "0" ]] && echo "E2E OK" || { echo "E2E FAILED"; exit 1; }
