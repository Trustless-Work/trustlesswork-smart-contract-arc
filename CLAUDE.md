# Trustless Work escrow contracts on Arc — agent context

Solidity (Foundry) ports of the Trustless Work **v2 escrows** from Soroban/Stellar to **Arc**, Circle's EVM L1
where gas is paid in USDC. The same file lives on both branches of this repo. `README.md` has the per-branch
details for humans; this file holds what a new session needs to work safely across the whole Arc project.

## The Arc project at a glance

Five sibling folders under `~/Documents/Programacion/Proyectos/`:

| Folder | GitHub (Trustless-Work org) | Role | Branches |
| --- | --- | --- | --- |
| `Trustless-Work-Arc-Escrow` (**this repo**) | `trustlesswork-smart-contract-arc` (internal) | Solidity contracts | `single-release-v2`, `multi-release-v2`: **one contract per branch** |
| `Trustless-Work-Arc-API` | `trustlesswork-core-api-arc` (internal) | NestJS REST API that builds unsigned transactions for these contracts | `main` |
| `Trustless-Work-Arc-Backoffice` | not on GitHub yet | Next.js backoffice on top of the API: deploy, fund and run escrows with MetaMask or a local dev wallet | `main` |
| `Trustless-Work-Smart-Escrow` | `trustlesswork-smart-contract-stellar` | **Soroban (Rust) source of truth** the ports follow | `single-release-develop-v2`, `multi-release-develop-v2` (use `origin/…`) |
| `Trustless-Work-Core` | `trustlesswork-core-api` | Stellar core API that the Arc API mirrors (routes, fields, error codes) | `main` |

Hard rules for the whole project:

- **Arc code never goes into the Rust repo.** No `evm/` folder, no Arc branches, no commits there. Read it
  with `git -C ../Trustless-Work-Smart-Escrow fetch origin` followed by
  `git -C ../Trustless-Work-Smart-Escrow show origin/<branch>:contracts/escrow/src/<file>`. Its local
  checkout is often behind.
- **Contract changes land here first, then in the API** (see [Change propagation](#change-propagation)).
- Code, comments, docs and git artefacts are in **English**, even when the conversation is in Spanish. Commit
  subjects are short, with no AI or Co-Authored-By trailers.
- **Ask before pushing** here unless the user said so for that change. For the API repo the user allows direct
  pushes to `main`.

## What the contracts are

A **factory** deploys one **EIP-1167 clone** per escrow with CREATE2, and initializes it in the same
transaction (no front-running window).

- **Salt:** bound to `msg.sender`, so `predictEscrowAddress(creator, salt)` is known before the transaction.
- **Implementation:** fixed, deployed by the factory's constructor. It plays the role of Soroban's approved
  WASM hash.
- **Trustless Work fee recipient:** stored in the factory (`Ownable2Step`), so the owner can rotate it.

| Branch | Contracts | Money model |
| --- | --- | --- |
| `single-release-v2` | `SingleReleaseEscrow`, `SingleReleaseEscrowFactory`, `ISingleReleaseEscrow` | One `amount`, one `roles.receiver`. Milestones gate a single `releaseFunds()`. |
| `multi-release-v2` | `MultiReleaseEscrow`, `MultiReleaseEscrowFactory`, `IMultiReleaseEscrow`, `libraries/MultiReleaseValidation` | Each milestone has `amount`, `receiver`, `dispute`, `released`. `releaseFunds(indexes)`, `disputeMilestones(indexes, reason)`, `resolveDispute(indexes, recipients, amounts)`. |

### Porting rules (both branches)

- **Check-for-check parity with Soroban v2**, in the **same order**, with the **same error names**. The
  Soroban `EscrowError` / `MilestoneError` / `ReleaseError` enums become custom errors in the interface; a name
  shared by several enums is declared once.
- `x.require_auth()` on a role argument becomes a `msg.sender` check, so those arguments disappear.
  `trustless_work_address` is not an argument either: it comes from the factory.
- The rest of the type mapping:
  - `Trustline` → `address token` (ERC-20; on Arc, USDC);
  - `i128` → `uint256`, with `Math.mulDiv` for fee math;
  - `Map<Address, i128>` → parallel `address[]` / `uint256[]` arrays (duplicates, zero addresses and length
    mismatches revert);
  - `Option<T>` → a `set*` flag plus a value;
  - hashes in events stay SHA-256;
  - `expected_escrow` → `escrowHash() = keccak256(abi.encode(getEscrow()))`, passed to `fundEscrow`.
- Removed on EVM: TTL (`extend_contract_ttl`); `get_escrow_by_contract_id` (callers read the escrow directly).
  `get_multiple_escrow_balances` moved to the factory.
- **Deliberate deviations** (documented in each README): the fee recipient is fixed by the factory; the
  rounding remainder goes to the last recipient in array order; funding credits the balance delta;
  zero-address checks; errors are not remapped. On multi-release, two Soroban rule gaps are closed:
  - update overlap checks run against the **stored** milestones;
  - new milestones cannot arrive disputed or resolved.

  Drafts for the upstream issues live in `docs/issues/` on `multi-release-v2`.

### Multi-release: the validation library

With every rule inline, the multi-release escrow exceeded the 24 KB EIP-170 limit (it would not deploy from
Remix). All rules therefore live in `MultiReleaseValidation`, an external library that the escrow calls with
DELEGATECALL. Current sizes: escrow 20.5 KB with via-IR, 18.9 KB without.

- The factory bytecode embeds the escrow bytecode, which carries a `__$<hash>$__` placeholder, so **the
  library must be deployed first and linked**.
- `forge script script/Deploy.s.sol` does this automatically. `forge create` needs
  `--libraries src/libraries/MultiReleaseValidation.sol:MultiReleaseValidation:<addr>` (see `script/e2e.sh`).
- The API's anvil tests link it with `linkLibrary` in `test/utils/anvil.ts`.
- Library reverts use `IMultiReleaseEscrow` errors, so the escrow ABI decodes them.
- Keep an eye on sizes: `forge build --sizes`, and also `FOUNDRY_VIA_IR=false forge build --sizes` for Remix
  users.

## Arc facts that shape the code

- **Networks:** testnet chain `5042002`, RPC `https://rpc.testnet.arc.io`, explorer
  `https://explorer.testnet.arc.io`, faucet `https://faucet.circle.com`. Mainnet chain `5042`.
- **USDC has two faces over one balance:** native gas token with 18 decimals, and ERC-20
  `0x3600000000000000000000000000000000000000` with 6 decimals (EIP-2612 `permit`, FiatToken v2, blocklist).
  The escrows only use the ERC-20 face and have no payable function. Gas comes out of the same USDC a role
  receives, so balance deltas of a signer are not exact.
- **Arc's USDC moves balances through node precompiles (`0x1800…`) that Foundry cannot emulate.** Token
  transfers fail on a local fork and inside `forge script`, because the script simulates first. Hence:
  - `test/fork/ArcFork.t.sol` only checks what works: decimals, native/ERC-20 mirroring, creation, hashes.
  - Real transfer flows run with `cast send` in `script/e2e.sh` against a live network.
  - Unit tests use a 6-decimal `MockUSDC` with permit.
- **EVM target:** Arc runs Osaka; `foundry.toml` targets `prague`, a subset of it that includes the transient
  storage used by `ReentrancyGuardTransient`. `via_ir = true`, 200 optimizer runs, solc `0.8.30`.

## Deployed on Arc testnet (test data, as of 2026-09-30)

| What | Address |
| --- | --- |
| Single-release factory (owner and fee recipient = test account A) | `0x4d819Dd3a6af9E0323102cf71E1D0FE29904F802` |
| Single-release escrow `ENG-001` (released) | `0x35F4457491F7f9Dd7D2457483A751469675710B4` |
| Single-release escrow `ENG-002` (approved, unfunded) | `0x9AE6A0668d8Fd9FDD6EDae30b7FA29B23489D800` |
| Multi-release factory (owner and fee recipient = test account A; `forge script`, block 64850225) | `0x6CC61Bf5c4bd56290189265964b66A9b2CCD7458` |
| Multi-release escrow implementation (created by that factory) | `0xBe6E5693FE6f5b27c218780e7773dFBd7ae6E6c8` |
| `MultiReleaseValidation` library (linked into the implementation) | `0x9487397A8A97C828AABFEA85291c85f1eAe36b91` |

The user's test accounts: A `0x3025B4E63cdbBF2a12981fF38E7678C5a52e0D34` (admin, platform, funder),
B `0x40BC51511ad79166FCc3506bea745A928f7E2708` (approver, provider, release signer, receiver) and C
`0xE57f683F965de94c377Dc97E78E1A6d89e5531df` (dispute resolver). Never ask for or handle their keys; the user
signs.

## Commands

```bash
git submodule update --init --recursive      # forge-std, OpenZeppelin v5.4.0
forge build --sizes
forge test                                    # unit + fuzz
forge test --match-path test/fork/ArcFork.t.sol --fork-url arc_testnet
forge fmt                                     # must be clean before committing
FACTORY_OWNER=0x… TW_FEE_RECIPIENT=0x… forge script script/Deploy.s.sol --rpc-url arc_testnet --private-key … --broadcast
PRIVATE_KEY=0x… ./script/e2e.sh              # live flow; test on anvil with RPC_URL/USDC overrides first
```

**Definition of done:** `forge fmt --check`, `forge test` green, runtime size under 24,576 bytes (with and
without via-IR on multi-release), and the API synced and green if an ABI changed.

## Change propagation

1. **The Soroban contract changes upstream.** Diff
   `origin/<kind>-release-develop-v2` in the Rust repo, ignoring `tests/`. Soroban SDK bumps (e.g. protocol 28's
   `deploy_v2` → `deploy_contract`) do not affect the port.
2. **Port it here**, `single-release-v2` first, then `multi-release-v2` (the user audits both and wants them
   aligned). Add tests like the Rust ones and keep the check order.
3. **Commit** on each branch. Push only when asked.
4. **In the API** (`../Trustless-Work-Arc-API`):
   - check out the branch here, `forge build`, then run `npm run contracts:sync -- single|multi`;
   - if a new error appears, map it in `src/domain/escrow/<kind>-contract-errors.ts` (a unit test fails
     until you do);
   - update the DTOs and use cases if a signature changed;
   - run `npm test && npm run test:e2e`.
5. **In the backoffice** (`../Trustless-Work-Arc-Backoffice`), only if the API's wire shape changed: update
   `src/features/arc-api/types.ts` and the affected dialogs. `npm run local` in the API gives it a chain
   with the new contracts to click through.

`CLAUDE.md` is the same on both branches. When you change it, apply the change to both (cherry-pick).

## Traps already hit

- `vm.prank` applies to the **next call**, including one evaluated as an argument:
  `vm.prank(a); x.f(x.getEscrow())` pranks `getEscrow`. Compute the argument first.
- Copying nested struct arrays from calldata to storage is not supported; milestones are pushed field by field
  (`_pushMilestone`).
- Clones read `immutable`s from the implementation's bytecode (e.g. `factory`). Storage lives in each clone.
- Remix: enable optimization (without it single-release is 34.7 KB). It hides interfaces from the contract list,
  so load USDC through a tiny concrete contract with the ERC-20 functions. MetaMask remembers a network per site.
- Remix's gas-estimation popup shows custom errors as raw selectors (`0x21d9821d`): decode them with
  `cast sig "Name()"`.
- `app/` may exist untracked on the local checkout: a paused dApp experiment. Never commit it.
