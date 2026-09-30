# Design: export owned vouchers to the policy

Status: **proposed, awaiting architecture review.** No code yet.

## Why

The policy's economy model fixes the interest cap at $25 (5 interest), so it
cannot value Seed Money (cap $50) or Money Tree (cap $100). It also re-offers
tier-2 voucher values without knowing the tier-1 voucher is owned. The
observation schema already has `self.vouchers`
(`AISparring/ai/observation.lua`, section `vouchers`, fields `center`, `cost`),
but neither the engine adapter nor the state reader fills it.

## Fairness

Redeemed vouchers are public information about the AI's own run: Balatro shows
them in Run Info → Vouchers, and the human sees their own the same way. Only
the AI's own `G.GAME.used_vouchers` is read. No opponent data, no future shop
or voucher pool, no RNG state.

## Data flow

The same pattern as `hand_levels`: plain data copied through an allowlist, with
no binding to engine card objects.

1. **Adapter** (`engine_adapter.lua`, `build_self`):
   - read `G.GAME.used_vouchers` with the adapter's `rget`;
   - keep keys whose value is `true` and that match `^v_[a-z0-9_]+$` (at most
     32 characters);
   - sort them bytewise and keep at most 32;
   - emit `self_view.owned_vouchers = { "v_...", ... }`, or nothing when empty
     or unreadable. Never fail the frame for this field.
2. **Reader** (`state_reader.lua`, `build_self`):
   - `copy_owned_vouchers(rget(view_self, "owned_vouchers"))`: a plain array of
     at most 32 strings, each matching the same pattern, strictly increasing;
     anything else is `CODE.BAD_VIEW`;
   - output `out.vouchers = { { face_down = false, center = key }, ... }`.
     There are no refs and no engine objects, and no action ever targets these
     records.
3. **Observation** (unchanged): `self.vouchers` is read through the existing
   `convert_entity("voucher", "voucher")`, which assigns ids `voucher:N`. `cost`
   is absent, which that path allows.
4. **Policy** (`baseline_policy.lua`):
   - `economy_bonus` uses an interest cap of 10 with `v_seed_money` and 20 with
     `v_money_tree`;
   - `VOUCHER_VALUE` for a tier-2 voucher applies only when its tier-1 is owned
     (the game only offers it then anyway).

## Bounds and failure

- At most 32 keys; the game has 32 base vouchers.
- A malformed field is dropped by the adapter (fail-soft) but rejected by the
  reader (fail-closed). This matches the other allowlisted view fields.
- Modded vouchers with other key shapes are dropped, not passed through.

## Tests

- **Adapter fixture:** `used_vouchers` produces the sorted list; a non-`true`
  value, a bad key or more than 32 keys is filtered or capped.
- **Reader:**
  - a valid list becomes `self.vouchers`;
  - a non-array, a non-string, a bad pattern, an unsorted list or more than
    32 entries gives `BAD_VIEW`;
  - hidden fields added to the view never appear in the output.
- **Policy:** interest cap 10/20 with Seed Money / Money Tree changes a
  spend-vs-save decision; without owned vouchers behaviour is unchanged.
- **Isolation certificate / cross-service:** re-run.

## Out of scope

Tags, the opponent's vouchers, and the voucher pool.
