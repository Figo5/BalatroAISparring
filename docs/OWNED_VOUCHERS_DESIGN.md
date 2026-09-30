# Design: export owned vouchers to the policy

Status: **implemented.** The architecture review approved it with changes,
all applied:

- **Critical:** owned vouchers have their own bound of 32 (`LIMIT.owned_vouchers`
  / `LIMITS.owned_vouchers`). They no longer share the shop's 16, which would
  have rejected the whole observation in long runs.
- **High:** the reader, adapter and observation docs are updated.
- **Medium:**
  - sorting and the strictly-increasing check are bytewise, not locale `<`;
  - the interest cap is per decision (`INTEREST_CAP`, reset at entry; `CONF`
    is never mutated);
  - the tests from the review are added.
- **Low:**
  - the adapter inspects at most 256 entries;
  - a key must be a real Voucher center (`G.P_CENTERS[key].set == "Voucher"`,
    read raw), as Run Info lists;
  - `v_mp_*` keys pass through and score 0 in `VOUCHER_VALUE`.

Re-certification is required: `observation.lua`, `baseline_policy.lua`, the
adapter and the reader all changed, so existing isolation certificates and
staged digests are stale by design.

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
   - require raw `G.P_CENTERS[key].set == "Voucher"`, inspect at most 256
     entries;
   - sort them bytewise (explicit byte comparator) and keep at most 32;
   - emit `self_view.owned_vouchers = { "v_...", ... }`, or nothing when empty
     or unreadable. Never fail the frame for this field.
2. **Reader** (`state_reader.lua`, `build_self`):
   - `copy_owned_vouchers(rget(view_self, "owned_vouchers"))`: a plain array of
     at most 32 strings, each matching the same pattern, strictly increasing;
     anything else is `CODE.BAD_VIEW`;
   - output `out.vouchers = { { face_down = false, center = key }, ... }`.
     There are no refs and no engine objects, and no action ever targets these
     records.
3. **Observation:** `self.vouchers` is read through the existing
   `convert_entity("voucher", "voucher")`, which assigns ids `voucher:N`. `cost`
   is absent, which that path allows. The one schema change is its own bound,
   `LIMIT.owned_vouchers` = 32; shop vouchers keep 16.
4. **Policy** (`baseline_policy.lua`):
   - `economy_bonus` uses an interest cap of 10 with `v_seed_money` and 20 with
     `v_money_tree`; Money Tree alone gives 20;
   - tier-2 gating is not needed, because the game offers a tier-2 voucher only
     once its tier-1 is owned.

   Green Deck, no-interest rulesets and To the Moon change the interest paid
   per $5, not the cap. They are out of scope.

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
