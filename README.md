# Multi-Release Escrow v2 on Arc (EVM)

Solidity port of the Soroban **multi-release** escrow v2 for [Arc](https://docs.arc.io), Circle's EVM L1 with USDC as
the native gas token. The Soroban source lives in the separate
[trustlesswork-smart-contract-stellar](https://github.com/Trustless-Work/trustlesswork-smart-contract-stellar)
repository (`contracts/escrow/src`, branch `multi-release-develop-v2`). This repository contains no Rust code.

The branches mirror the Stellar repository:

| Branch | Contract |
| --- | --- |
| `single-release-v2` | Single-release escrow: one amount and one receiver, released all at once. |
| `multi-release-v2` (this one) | Multi-release escrow: each milestone is a mini-escrow with its own amount, receiver, dispute and release. |

Business rules match the Soroban contract: roles, overlap rules, limits, approval thresholds, the per-milestone
release and dispute flow, fee math and error names. The differences come from moving to the EVM, plus two rule
gaps that the port closes (see [Behavioural differences](#behavioural-differences-to-be-aware-of)).

## Layout

| Path | Purpose |
| --- | --- |
| `src/MultiReleaseEscrow.sol` | Escrow logic (state changes and token transfers). One EIP-1167 clone per escrow. |
| `src/libraries/MultiReleaseValidation.sol` | Every validation rule, check for check, in the Soroban order. External library, called with DELEGATECALL. |
| `src/MultiReleaseEscrowFactory.sol` | Deploys and initializes clones atomically; holds the Trustless Work fee recipient. |
| `src/utils/CalldataExecutor.sol` | `execute(bytes)`, inherited by the factory and the escrow: runs one of the contract's own functions from its ABI-encoded calldata. |
| `src/interfaces/IMultiReleaseEscrow.sol` | Structs, errors and events (the Rust `storage/types.rs`, `error.rs`, `events/handler.rs`). |
| `test/` | Unit and fuzz tests with a 6-decimal EIP-2612 mock of USDC. |
| `test/fork/ArcFork.t.sol` | Checks against the real Arc testnet USDC. |
| `script/Deploy.s.sol` | Deploys the library and the factory. |
| `script/e2e.sh` | Live happy path (two milestones, two receivers, released one by one) using `cast`. |

## The data model

```
Escrow
├── engagementId, title, description, platformFee, token, receiverMemo
├── roles: approvers[], serviceProviders[], platform, releaseSigners[], disputeResolvers[], admin, observers[]
└── milestones[]                 ← each one is released or disputed on its own
    ├── description, status, evidence
    ├── approvals { target, approvalCount, approvedBy[] }
    ├── amount                   ← what this milestone pays
    ├── receiver                 ← who this milestone pays
    ├── dispute { isDisputed, reason, resolved }
    └── released
```

There is no escrow-level amount, receiver, dispute or release flag. The escrow total is the sum of the
milestone amounts.

## Lifecycle

| Action | Who | What it does |
| --- | --- | --- |
| `factory.createEscrow(salt, escrow)` | anyone | Deploys and initializes the escrow. |
| `fundEscrow(amount, escrowHash)` | anyone | Deposits USDC (after `approve`). It can fund part of the total, in several deposits. |
| `changeMilestoneStatus(updates)` | service provider | Status and evidence. They freeze once that milestone is released or resolved. |
| `approveMilestones(indexes)` | approver | Counts towards each milestone's approval `target`. |
| `releaseFunds(indexes)` | release signer | Pays each listed milestone to its own receiver, minus fees. It needs a balance covering the whole batch. |
| `approveAndReleaseMilestones(indexes)` | approver + release signer | Approves and releases the same milestones in one transaction. |
| `disputeMilestones(indexes, reason)` | a global role, or a receiver for its own milestones | Blocks the release of those milestones only. |
| `resolveDispute(indexes, recipients, amounts)` | dispute resolver | Splits exactly the sum of those milestones' amounts, then marks them resolved. |
| `withdrawRemainingFunds(recipients, amounts)` | dispute resolver | Once every milestone is released or resolved, sweeps the leftover balance. |
| `updateEscrow(escrow)` | admin | Edits the properties (locked once funded). The milestones are kept from storage. |
| `manageMilestones(new, updates)` | admin | Adds milestones (allowed after funding) or edits description/amount (before funding only). |

The global roles that can open a dispute are approvers, service providers, the platform and release signers.

## Soroban → EVM mapping

| Soroban v2 | Arc / EVM |
| --- | --- |
| `tw_new_multi_release_escrow` + approved WASM hash + `initialize_escrow` | `factory.createEscrow(salt, escrow)`: CREATE2 clone of a fixed implementation, initialized in the same transaction. The salt is bound to `msg.sender`. |
| `x.require_auth()` on a role argument | `msg.sender` check. The role arguments (`signer`, `approver`, `release_signer`…) are gone. |
| `trustless_work_address` passed by the caller on every release or resolution | Read from `factory.trustlessWorkFeeRecipient()`, which only the factory owner (`Ownable2Step`) can change. |
| `Trustline { address }` | `address token`: any ERC-20. On Arc this is USDC at `0x3600000000000000000000000000000000000000`. |
| `i128` amounts | `uint256`. Checked arithmetic is built in, and `Math.mulDiv` replaces `safe_mul_div` and `mul_div_wide`. |
| `fund_escrow(signer, expected_escrow, amount)` | `fundEscrow(amount, expectedEscrowHash)`, with `escrowHash() = keccak256(abi.encode(getEscrow()))`. Also `fundEscrowWithPermit` (EIP-2612, one transaction). |
| `Map<Address, i128>` distributions | Parallel arrays `address[] recipients, uint256[] amounts`. Duplicates, zero addresses and length mismatches revert. |
| `Option<String>` / `Option<i128>` in updates | A `set*` flag plus a value (`setDescription`, `setAmount`). |
| `Option<…>` in events | `bytes32` zero for "untouched" hashes, and `amountChanged` + `newAmount` for the amount. Hashes stay SHA-256. |
| `DataKey::Reentrancy` | OpenZeppelin `ReentrancyGuardTransient` (EIP-1153) on every function that moves tokens. |
| `core/validators/*` | `MultiReleaseValidation`, an external library. It exists only because of the contract size limit (below). |
| `extend_contract_ttl`, `TtlExtended` | Removed. The EVM has no state rent. |
| `get_multiple_escrow_balances` | `factory.getMultipleEscrowBalances(escrows)` (max 20). |
| `EscrowError` / `ReleaseError` / `MilestoneError` enums | Custom errors with the same names. A name used in several enums is declared once. |

### Behavioural differences to be aware of

- **Fee recipient.** In Soroban the caller picked `trustless_work_address`, so a release signer or dispute resolver
  could send the 0.3% fee anywhere. Here it is fixed by the factory.
- **Rounding remainder in disputes.** It still goes to the last paid recipient. The order is now the order of the
  array, where Soroban used the sorted `Map` key order.
- **Funding credits the amount actually received** (the balance delta), so fee-on-transfer tokens cannot inflate
  `fundedAmount`.
- **Zero-address checks** apply to the token, platform, admin, every role list and every milestone receiver.
- **Error surfacing.** Errors come out with their own names. Soroban remaps them through
  `From<MilestoneError/ReleaseError> for EscrowError` in `approve_and_release_milestones`; for example, the
  milestone batch limit there becomes `TooManyMilestones` in Soroban and stays `BatchTooLarge` here.
- **`execute(bytes)`, an Arc-only addition.** The factory and the escrow accept the ABI-encoded call to any of their
  own functions and run it with a delegatecall to themselves, so `msg.sender` and every check stay the same. It
  exists because Circle CLI agent wallets (`circle wallet execute`, CLI 1.1.4) can pass `bytes` but cannot encode
  array or tuple arguments. Soroban has no counterpart.
- **Rule gap 1: `update_escrow` overlap checks.** Soroban checks "a dispute resolver or the admin must not be a
  milestone receiver" against the milestones passed in the argument, but it stores the existing milestones and
  ignores the argument. Before funding, an admin could pass look-alike milestones and make a real receiver a
  resolver. The port checks against the stored milestones
  (`test_update_checks_overlap_against_stored_milestones`).
- **Rule gap 2: `manage_milestones` dispute flags.** Soroban checks approvals and `released` on new milestones, but
  not `dispute.is_disputed` or `dispute.resolved`, so a milestone could be added already disputed or resolved. The
  port rejects them with `FlagsMustBeFalse`, as `initialize` does
  (`test_manage_milestones_rejects_new_milestone_with_dispute_state`).

Both gaps are worth fixing in the Soroban contract too.

## Arc-specific notes

- **Chain IDs:** testnet `5042002`, mainnet `5042`. RPC endpoints are `https://rpc.testnet.arc.io` and
  `https://rpc.mainnet.arc.io`. Get testnet funds from the faucet at https://faucet.circle.com.
- **Decimals.** USDC has 18 decimals as the native gas token and 6 decimals through its ERC-20 interface. Both views
  share one balance. The escrow only uses the ERC-20 interface (6 decimals) and has no payable function.
- **Gas is paid in USDC.** A role that sends transactions spends USDC from the same balance it receives payouts in.
- **USDC blocklist.** A blocklisted receiver makes the release of its milestone revert. The way out is to dispute
  that milestone and resolve it to another address.
- **No local fork for transfers.** Arc's USDC moves balances through node-level system precompiles (`0x1800…`), which
  Foundry's EVM does not implement. Token transfers therefore cannot run on a local fork or inside `forge script`.
  The fork test covers what can run locally, and `script/e2e.sh` runs the real flow on-chain.
- **EVM target.** Arc runs Osaka. This build targets `prague`, a subset of Osaka that still includes the transient
  storage used by the reentrancy guard.

### Contract size and the validation library

With every rule inline, the escrow measured 24.1 KB with via-IR and 25.5 KB without it. The EVM rejects contracts
above 24 KB (EIP-170), so the rules moved to `MultiReleaseValidation`. Current sizes:

| Contract | via-IR (`foundry.toml`) | without via-IR (Remix default) |
| --- | --- | --- |
| `MultiReleaseEscrow` | 20.8 KB | 19.3 KB |
| `MultiReleaseValidation` | 9.0 KB | 12.5 KB |

The library is deployed once and shared by every escrow. Its address is linked into the escrow bytecode, which
the factory embeds, so it has to exist before the factory:

- `forge script script/Deploy.s.sol` deploys and links it automatically.
- `forge create` needs it first, then
  `--libraries src/libraries/MultiReleaseValidation.sol:MultiReleaseValidation:<address>` (see `script/e2e.sh`).
- Remix deploys linked libraries automatically when you deploy the factory. Enable optimization when compiling.

## Usage

```bash
git submodule update --init --recursive
forge build
forge test                                                            # unit + fuzz tests
forge test --match-path test/fork/ArcFork.t.sol --fork-url arc_testnet
```

Deploy the library and the factory:

```bash
FACTORY_OWNER=0x... TW_FEE_RECIPIENT=0x... forge script script/Deploy.s.sol \
  --rpc-url arc_testnet --private-key $PRIVATE_KEY --broadcast
```

Run the live end-to-end flow. The key needs about 1.5 testnet USDC:

```bash
PRIVATE_KEY=0x... ./script/e2e.sh
```

### Integration flow

1. `factory.predictEscrowAddress(creator, salt)` returns the escrow address before it exists.
2. `factory.createEscrow(salt, escrow)` deploys and initializes the escrow and emits `EscrowCreated`. Each milestone
   carries `amount` and `receiver`.
3. The funder calls `usdc.approve(escrow, amount)` and then `escrow.fundEscrow(amount, escrow.escrowHash())`.
4. Per milestone, the service provider calls `changeMilestoneStatus`, approvers call `approveMilestones`, and a release
   signer calls `releaseFunds([indexes])`. Every listed milestone pays its own receiver.
5. For a dispute, a party calls `disputeMilestones([indexes], reason)`. A resolver then calls
   `resolveDispute([indexes], recipients, amounts)`, whose amounts add up to those milestones' amounts. The other
   milestones keep working meanwhile.
6. Once every milestone is released or resolved, `withdrawRemainingFunds` sweeps any leftover balance.
