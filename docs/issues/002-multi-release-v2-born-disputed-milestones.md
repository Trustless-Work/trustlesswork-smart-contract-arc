# [multi-release v2] `manage_milestones` accepts new milestones that are already disputed or resolved

> **Target repository:** `trustlesswork-smart-contract-stellar`, branch `multi-release-develop-v2` (verified at `ab06d9c`).
> **Suggested labels:** `bug`, `security`, `multi-release`, `v2`
> **Suggested severity:** High. It moves escrowed funds with no approval and no release signer, but it needs the
> admin and a dispute resolver acting together.

## Summary

`initialize_escrow` rejects milestones that carry runtime state (approvals, `released`, `dispute.is_disputed`,
`dispute.resolved`) with `FlagsMustBeFalse`. `manage_milestones` runs a weaker version of that check on the milestones
it appends. It covers approvals and `released`, but **not the dispute flags**:

```rust
// core/validators/escrow.rs:318-323
if milestone.approvals.approval_count > 0
    || !milestone.approvals.approved_by.is_empty()
    || milestone.released
{
    return Err(EscrowError::FlagsMustBeFalse);
}
```

The admin can therefore append a milestone that is born `is_disputed = true` or `resolved = true`. Adding milestones is
allowed **after funding**.

## Affected code

| File | Line | What |
| --- | --- | --- |
| `contracts/escrow/src/core/validators/escrow.rs` | 274 | `validate_manage_milestones_conditions` |
| `contracts/escrow/src/core/validators/escrow.rs` | 318–323 | flags check without `dispute.is_disputed` / `dispute.resolved` |
| `contracts/escrow/src/core/validators/escrow.rs` | 207–215 | the complete check that `initialize_escrow` uses, for comparison |

## Impact

**Born disputed: funds leave with no approval.** After the escrow is funded:

1. The admin appends a milestone for amount X, with any receiver, already marked `is_disputed`.
2. A dispute resolver calls `resolve_dispute` on it. `validate_dispute_resolution_conditions` only checks that the
   milestone is disputed, that the distributions add up to its amount, and that the **total** escrow balance
   covers it.
3. X leaves the escrow, even though that money was deposited for the other milestones.

No approver, release signer or party ever had a say, and no one opened a dispute. The legitimate milestones end
up under-funded. It needs the admin and a resolver together, two roles that are meant to check each other.

**Born disputed: the escrow freezes.** While such a milestone exists, `update_escrow` and `manage_milestones`
fail with `EscrowOpenedForDisputeResolution`.

**Born resolved.** The milestone counts as processed, which feeds the precondition of `withdraw_remaining_funds`.
It also blocks every later `manage_milestones` call with `EscrowAlreadyResolved`.

Single-release v2 is **not** affected: its milestones have no dispute or release state.

## Reproduction

Add to `contracts/escrow/src/tests/` (and `mod repro;` in `tests/mod.rs`):

```rust
extern crate std;

use crate::error::EscrowError;
use crate::storage::types::{
    Dispute, Escrow, Milestone, MilestoneApprovals, MilestoneUpdate, Roles, Trustline,
};
use soroban_sdk::{testutils::Address as _, vec, Address, Env, String, Vec};

use super::helpers::{create_escrow_contract, create_usdc_token};

fn milestone(env: &Env, receiver: &Address, amount: i128) -> Milestone {
    Milestone {
        description: String::from_str(env, "Deliverable"),
        status: String::from_str(env, "Pending"),
        evidence: String::from_str(env, ""),
        approvals: MilestoneApprovals {
            target: 1,
            approval_count: 0,
            approved_by: vec![env],
        },
        amount,
        dispute: Dispute {
            is_disputed: false,
            reason: String::from_str(env, ""),
            resolved: false,
        },
        released: false,
        receiver: receiver.clone(),
    }
}


/// Issue 2: manage_milestones accepts a new milestone that is already
/// disputed or resolved.
#[test]
fn manage_milestones_must_reject_new_milestones_with_dispute_state() {
    let env = Env::default();
    env.mock_all_auths();

    let token_admin = Address::generate(&env);
    let escrow_admin = Address::generate(&env);
    let receiver = Address::generate(&env);
    let (token, _) = create_usdc_token(&env, &token_admin);

    let escrow = Escrow {
        engagement_id: String::from_str(&env, "born-disputed"),
        title: String::from_str(&env, "Born disputed"),
        description: String::from_str(&env, "New milestone arrives disputed"),
        roles: Roles {
            approvers: vec![&env, Address::generate(&env)],
            service_providers: vec![&env, Address::generate(&env)],
            platform: Address::generate(&env),
            release_signers: vec![&env, Address::generate(&env)],
            dispute_resolvers: vec![&env, Address::generate(&env)],
            admin: escrow_admin.clone(),
            observers: vec![&env],
        },
        platform_fee: 0,
        milestones: vec![&env, milestone(&env, &receiver, 1_000)],
        trustline: Trustline { address: token.address.clone() },
        receiver_memo: 0,
    };
    let client = create_escrow_contract(&env, &escrow_admin).client;
    client.initialize_escrow(&escrow);

    let no_updates: Vec<MilestoneUpdate> = vec![&env];

    let mut disputed = milestone(&env, &receiver, 500);
    disputed.dispute.is_disputed = true;
    let result = client.try_manage_milestones(&escrow_admin, &vec![&env, disputed], &no_updates);
    assert_eq!(
        result.map(|_| ()),
        Err(Ok(EscrowError::FlagsMustBeFalse)),
        "a new milestone must not be born disputed"
    );

    let mut resolved = milestone(&env, &receiver, 500);
    resolved.dispute.resolved = true;
    let result = client.try_manage_milestones(&escrow_admin, &vec![&env, resolved], &no_updates);
    assert_eq!(
        result.map(|_| ()),
        Err(Ok(EscrowError::FlagsMustBeFalse)),
        "a new milestone must not be born resolved"
    );

}

/// Issue 2, impact: a milestone added already disputed after funding lets the
/// dispute resolver pay out money that was deposited for other milestones,
/// with no approval, no release signer and no party ever opening a dispute.
#[test]
fn born_disputed_milestone_lets_resolver_pay_out_other_milestones_funds() {
    use soroban_sdk::Map;

    let env = Env::default();
    env.mock_all_auths();

    let token_admin = Address::generate(&env);
    let escrow_admin = Address::generate(&env);
    let receiver = Address::generate(&env);
    let resolver = Address::generate(&env);
    let outsider = Address::generate(&env);
    let funder = Address::generate(&env);
    let tw = Address::generate(&env);
    let (token, token_admin_client) = create_usdc_token(&env, &token_admin);

    let escrow = Escrow {
        engagement_id: String::from_str(&env, "drain"),
        title: String::from_str(&env, "Drain"),
        description: String::from_str(&env, "Pay out another milestone's funds"),
        roles: Roles {
            approvers: vec![&env, Address::generate(&env)],
            service_providers: vec![&env, Address::generate(&env)],
            platform: Address::generate(&env),
            release_signers: vec![&env, Address::generate(&env)],
            dispute_resolvers: vec![&env, resolver.clone()],
            admin: escrow_admin.clone(),
            observers: vec![&env],
        },
        platform_fee: 0,
        milestones: vec![&env, milestone(&env, &receiver, 1_000_000)],
        trustline: Trustline { address: token.address.clone() },
        receiver_memo: 0,
    };
    let client = create_escrow_contract(&env, &escrow_admin).client;
    client.initialize_escrow(&escrow);
    token_admin_client.mint(&funder, &1_000_000);
    client.fund_escrow(&funder, &client.get_escrow(), &1_000_000);

    // Adding milestones is allowed after funding; this one arrives disputed.
    let mut disputed = milestone(&env, &outsider, 1_000_000);
    disputed.dispute.is_disputed = true;
    let no_updates: Vec<MilestoneUpdate> = vec![&env];
    client.manage_milestones(&escrow_admin, &vec![&env, disputed], &no_updates);

    let mut distributions = Map::new(&env);
    distributions.set(outsider.clone(), 1_000_000);
    client.resolve_dispute(&resolver, &tw, &vec![&env, 1u32], &distributions);

    // Milestone 0 was never approved or released, yet its funds are gone.
    assert_eq!(token.balance(&client.address), 0);
    assert!(token.balance(&outsider) > 0);
}
```

Results on `ab06d9c`:

- `manage_milestones_must_reject_new_milestones_with_dispute_state` **fails**: the call returns `Ok(())` where it
  should return `Err(Ok(FlagsMustBeFalse))`.
- `born_disputed_milestone_lets_resolver_pay_out_other_milestones_funds` **passes**: the escrow balance reaches 0,
  and milestone 0 was never approved or released.

## Expected behaviour

`manage_milestones` fails with `FlagsMustBeFalse` for any new milestone carrying `dispute.is_disputed` or
`dispute.resolved`, as `initialize_escrow` already does.

## Proposed fix

```diff
--- a/contracts/escrow/src/core/validators/escrow.rs
+++ b/contracts/escrow/src/core/validators/escrow.rs
@@ -318,6 +318,8 @@
             if milestone.approvals.approval_count > 0
                 || !milestone.approvals.approved_by.is_empty()
                 || milestone.released
+                || milestone.dispute.is_disputed
+                || milestone.dispute.resolved
             {
                 return Err(EscrowError::FlagsMustBeFalse);
             }
```

Verified on a copy of `ab06d9c`:

- the flags test passes;
- the drain scenario is blocked, because `manage_milestones` rejects the milestone;
- the full suite stays green (81 passed, 0 failed).

## Status on Arc

Fixed in the Solidity port (`trustlesswork-smart-contract-arc`, branch `multi-release-v2`):
`MultiReleaseValidation.validateManageMilestones` uses the same runtime-state check as `initialize`. Test:
`test_manage_milestones_rejects_new_milestone_with_dispute_state`.
