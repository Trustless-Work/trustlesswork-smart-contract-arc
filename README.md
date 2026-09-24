# Single-Release Escrow v2 on Arc (EVM)

Solidity port of the Soroban single-release escrow v2 for [Arc](https://docs.arc.io), Circle's EVM L1 with USDC as
the native gas token. The Soroban source lives in the separate [trustlesswork-smart-contract-stellar](https://github.com/Trustless-Work/trustlesswork-smart-contract-stellar) repository
(`contracts/escrow/src`, branch `single-release-develop-v2`); this repository contains no Rust code.

Business rules match the Soroban contract: roles, overlap rules, limits, milestone approval thresholds,
dispute flow, fee math and error names. The differences below come from moving to the EVM.

## Layout

| Path | Purpose |
| --- | --- |
| `src/SingleReleaseEscrow.sol` | Escrow logic. One EIP-1167 clone per escrow. |
| `src/SingleReleaseEscrowFactory.sol` | Deploys and initializes clones atomically; holds the Trustless Work fee recipient. |
| `src/interfaces/ISingleReleaseEscrow.sol` | Structs, errors and events (the Rust `storage/types.rs`, `error.rs`, `events/handler.rs`). |
| `test/` | Unit and fuzz tests with a 6-decimal EIP-2612 mock of USDC. |
| `test/fork/ArcFork.t.sol` | Checks against the real Arc testnet USDC. |
| `script/Deploy.s.sol` | Deploys the factory. |
| `script/e2e.sh` | Live happy path (create, fund, status, approve and release) using `cast`. |

## Soroban → EVM mapping

| Soroban v2 | Arc / EVM |
| --- | --- |
| `tw_new_single_release_escrow` + approved WASM hash + `initialize_escrow` | `factory.createEscrow(salt, escrow)`: CREATE2 clone of a fixed implementation, initialized in the same transaction. The salt is bound to `msg.sender`. |
| `x.require_auth()` on a role argument | `msg.sender` check. The `signer`, `approver`, `service_provider`, `release_signer`, `dispute_resolver` and `admin_address` arguments are gone. |
| `trustless_work_address` passed by the caller on every release or resolution | Read from `factory.trustlessWorkFeeRecipient()`, which only the factory owner (`Ownable2Step`) can change. |
| `Trustline { address }` | `address token`: any ERC-20. On Arc this is USDC at `0x3600000000000000000000000000000000000000`. |
| `i128` amounts | `uint256`. Checked arithmetic is built in, and `Math.mulDiv` replaces `safe_mul_div` and `mul_div_wide`. |
| `fund_escrow(signer, expected_escrow, amount)` | `fundEscrow(amount, expectedEscrowHash)`, where the hash is `escrowHash() = keccak256(abi.encode(getEscrow()))`. Also `fundEscrowWithPermit`, which funds in one transaction using EIP-2612. |
| `Map<Address, i128>` distributions | Parallel arrays `address[] recipients, uint256[] amounts`. Duplicates, zero addresses and length mismatches revert. |
| `Option<String>` in updates | A `set*` flag plus a value. |
| `Option<BytesN<32>>` hashes in events | `bytes32`, with zero meaning "untouched". Hashes stay SHA-256, as in Soroban. |
| `DataKey::Reentrancy` | OpenZeppelin `ReentrancyGuardTransient` (EIP-1153) on every function that moves tokens. |
| `extend_contract_ttl`, `TtlExtended` | Removed. The EVM has no state rent. |
| `get_multiple_escrow_balances` | `factory.getMultipleEscrowBalances(escrows)` (max 20). |
| `get_escrow_by_contract_id` | Call `getEscrow()` on the escrow address directly. |
| `EscrowError` / `MilestoneError` enums | Custom errors with the same names. A name used in both enums is declared once. |

### Behavioural differences to be aware of

- **Fee recipient.** In Soroban the caller picked `trustless_work_address`, so a release signer or dispute
  resolver could send the 0.3% fee anywhere. Here it is fixed by the factory.
- **Rounding remainder in disputes.** It still goes to the last paid recipient. The order is now the order of the
  array, where Soroban used the sorted `Map` key order.
- **Funding credits the amount actually received** (the balance delta), so fee-on-transfer tokens cannot inflate
  `fundedAmount`.
- **Zero-address checks** apply to the token, platform, receiver, admin and every role list. Soroban addresses cannot
  be zero, so these checks are new.
- **Error surfacing.** `approveAndReleaseMilestones` bubbles up milestone errors as they are, instead of mapping
  them with `From<MilestoneError> for EscrowError`.

## Arc-specific notes

- **Chain IDs:** testnet `5042002`, mainnet `5042`. RPC endpoints are `https://rpc.testnet.arc.io` and
  `https://rpc.mainnet.arc.io`. Get testnet funds from the faucet at https://faucet.circle.com.
- **Decimals.** USDC has 18 decimals as the native gas token and 6 decimals through its ERC-20 interface. Both views
  share one balance. The escrow only uses the ERC-20 interface (6 decimals) and has no payable function.
- **Gas is paid in USDC.** A role that sends transactions spends USDC from the same balance it receives payouts in.
- **USDC blocklist.** A blocklisted receiver makes `releaseFunds` revert, as it would with a frozen Stellar trustline.
  Once funded, the roles are locked. The only way out is the dispute flow.
- **No local fork for transfers.** Arc's USDC moves balances through node-level system precompiles
  (`0x1800…`), which Foundry's EVM does not implement. Token transfers therefore cannot run on a local fork or
  inside `forge script`. The fork test covers what can run locally, and `script/e2e.sh` runs the real flow on-chain.
- **EVM target.** Arc runs Osaka. This build targets `prague`, a subset of Osaka that still includes the transient
  storage used by the reentrancy guard.
- **Contract size.** The escrow runtime is 23.7 KB, just under the 24 KB EIP-170 limit. Porting CCTP or other large
  features will require moving validators into an external library.

## Usage

```bash
git submodule update --init --recursive
forge build
forge test                                                            # unit + fuzz tests
forge test --match-path test/fork/ArcFork.t.sol --fork-url arc_testnet
```

Deploy the factory:

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
2. `factory.createEscrow(salt, escrow)` deploys and initializes the escrow and emits `EscrowCreated`.
3. The funder calls `usdc.approve(escrow, amount)` and then `escrow.fundEscrow(amount, escrow.escrowHash())`.
   Alternatively, `fundEscrowWithPermit` does both in one transaction.
4. The service provider calls `changeMilestoneStatus`, approvers call `approveMilestones`, and a release signer calls
   `releaseFunds`. A signer holding both roles can call `approveAndReleaseMilestones` instead.
5. For disputes, a party calls `disputeEscrow` and then a resolver calls `resolveDispute(recipients, amounts)`.
   Any leftover balance can be swept with `withdrawRemainingFunds`.
