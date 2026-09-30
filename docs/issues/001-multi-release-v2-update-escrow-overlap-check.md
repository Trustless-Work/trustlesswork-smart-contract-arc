# [multi-release v2] `update_escrow` checks role overlaps against the milestones in the argument, not the stored ones

> **Target repository:** `trustlesswork-smart-contract-stellar`, branch `multi-release-develop-v2` (verified at `ab06d9c`).
> **Suggested labels:** `bug`, `security`, `multi-release`, `v2`
> **Suggested severity:** Medium. It needs the admin, and only works before the escrow is funded.

## Summary

`update_escrow` validates the new properties with `validate_escrow_conditions`, which enforces:

- a dispute resolver must not be the receiver of any milestone;
- the admin must not be the receiver of any milestone.

Both checks read the milestone receivers from `escrow_properties.milestones`, **the argument**. But
`change_escrow_properties` then throws the argument's milestones away and **keeps the stored ones**:

```rust
// core/escrow.rs:197
escrow_to_save.milestones = existing_escrow.milestones.clone();
```

The rules are therefore checked against milestones the contract never stores. An admin can send an empty (or
look-alike) milestone list and make the receiver of a real milestone a dispute resolver.

## Affected code

| File | Line | What |
| --- | --- | --- |
| `contracts/escrow/src/core/validators/escrow.rs` | 200 | `validate_dispute_resolver_role_overlap(&new_escrow.roles, &new_escrow.milestones)` |
| `contracts/escrow/src/core/validators/escrow.rs` | 267 | `validate_admin_role_overlap(&new_escrow.roles, &new_escrow.milestones)` (update branch) |
| `contracts/escrow/src/core/validators/escrow.rs` | 363 | `validate_escrow_property_change_conditions` passes the argument straight through |
| `contracts/escrow/src/core/escrow.rs` | 197 | the stored milestones replace the argument's |

## Impact

- The stored escrow breaks the invariant "a dispute resolver is never a milestone receiver". That rule exists
  because a receiver has a stake in how its milestone's disputes end.
- Once another party disputes that milestone, the resolver settles a dispute about its own payout and can
  route the funds to itself.
- The window is before funding: after the first deposit, any change to `roles` fails with
  `EscrowPropertiesMismatch`. The conflicting roles are visible in `get_escrow`, and a careful funder would see
  them in `expected_escrow`, but the contract promises to reject them.
- The admin half of the check cannot be exploited this way: `admin` cannot change, and neither can the stored
  receivers. It still validates the wrong data, and the fix covers it too.
- Single-release v2 is **not** affected: its receiver lives in `roles`, which is stored as sent.

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


/// Issue 1: update_escrow checks the resolver/admin overlap rules against the
/// milestones in the argument, but keeps the stored ones.
#[test]
fn update_escrow_must_check_overlap_against_stored_milestones() {
    let env = Env::default();
    env.mock_all_auths();

    let token_admin = Address::generate(&env);
    let escrow_admin = Address::generate(&env);
    let receiver = Address::generate(&env);
    let (token, _) = create_usdc_token(&env, &token_admin);

    let roles = Roles {
        approvers: vec![&env, Address::generate(&env)],
        service_providers: vec![&env, Address::generate(&env)],
        platform: Address::generate(&env),
        release_signers: vec![&env, Address::generate(&env)],
        dispute_resolvers: vec![&env, Address::generate(&env)],
        admin: escrow_admin.clone(),
        observers: vec![&env],
    };
    let escrow = Escrow {
        engagement_id: String::from_str(&env, "overlap-bypass"),
        title: String::from_str(&env, "Overlap bypass"),
        description: String::from_str(&env, "Receiver becomes resolver"),
        roles: roles.clone(),
        platform_fee: 0,
        milestones: vec![&env, milestone(&env, &receiver, 1_000)],
        trustline: Trustline { address: token.address.clone() },
        receiver_memo: 0,
    };
    let client = create_escrow_contract(&env, &escrow_admin).client;
    client.initialize_escrow(&escrow);

    // The admin names the milestone's receiver as dispute resolver and sends an
    // empty milestone list, so the overlap check has nothing to compare against.
    let mut update = escrow.clone();
    update.roles.dispute_resolvers = vec![&env, receiver.clone()];
    update.milestones = Vec::new(&env);

    let result = client.try_update_escrow(&escrow_admin, &update);
    assert_eq!(
        result.map(|_| ()),
        Err(Ok(EscrowError::DisputeResolverOverlapsWithOtherRole)),
        "the resolver is also the receiver of the stored milestone 0"
    );
}
```

Result on `ab06d9c`:

```
assertion `left == right` failed: the resolver is also the receiver of the stored milestone 0
  left: Ok(())
 right: Err(Ok(DisputeResolverOverlapsWithOtherRole))
```

## Expected behaviour

`update_escrow` fails with `DisputeResolverOverlapsWithOtherRole` (or `AdminAddressOverlapsWithOtherRole`) whenever
the new roles conflict with a receiver of a **stored** milestone.

## Proposed fix

Validate against the milestones that will actually be stored:

```diff
--- a/contracts/escrow/src/core/validators/escrow.rs
+++ b/contracts/escrow/src/core/validators/escrow.rs
@@ -366,9 +368,13 @@
     admin: &Address,
     contract_balance: i128,
 ) -> Result<(), EscrowError> {
+    // update_escrow keeps the stored milestones and discards the ones in the
+    // argument, so the milestone-receiver overlap rules must see the stored ones.
+    let mut effective = new_escrow.clone();
+    effective.milestones = existing_escrow.milestones.clone();
     validate_escrow_conditions(
         Some(existing_escrow),
-        new_escrow,
+        &effective,
         Some(admin),
         Some(contract_balance),
         false,
```

Verified on a copy of `ab06d9c`: the reproduction passes and the full suite stays green (81 passed, 0 failed). As a
side effect, the string-length checks also run on the stored milestones instead of the ignored ones.

## Status on Arc

Fixed in the Solidity port (`trustlesswork-smart-contract-arc`, branch `multi-release-v2`):
`MultiReleaseValidation.validateUpdate` reads the receivers from storage. Test:
`test_update_checks_overlap_against_stored_milestones`.
