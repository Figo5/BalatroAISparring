#!/usr/bin/env python3
"""Host-owned Ranked deck/stake ban-pick draft.

Architecture: ``docs/RANKED_INTEGRATION_PLAN.md`` (full ban-pick) and
``docs/RANKED_EFFECTIVE_CONFIG_V1.md`` (draft and post-start binding). This module
is the bounded, seed-independent draft state machine the attended Player menu
drives over the authenticated loopback control channel *before* the user quits for
staged launch.

Honesty boundaries:

* No production pool is invented. The pool is drawn from the measured, source-
  validated deck/stake catalog produced by the deployment slice; without it the
  host fails closed (it never falls back to a fixed deck). Explicit verified
  fixtures may exercise the complete source flow.
* Nothing here reads a gameplay or gauntlet seed. The AI's draft preferences are
  a fixed public ordering over the public pool, so they are invariant under any
  seed change.
* The commitment checksum is an equality primitive (FNV1a-32), identical in both
  languages and domain-separated from the lobby-config checksum. It is not
  authentication.

Importing this module performs no I/O and consumes no OS randomness.
"""
from __future__ import annotations

import secrets
import time
from typing import Mapping, Optional

from ranked_effective_config import (  # local authority module
    MAX_STAKE_INDEX,
    RankedConfigError,
    fnv1a32_hex,
)

DRAFT_SCHEMA = "aisparring.ranked_draft.v1"
DRAFT_COMMITMENT_DOMAIN = "aisparring.ranked_draft_commitment.v1"
DRAFT_PROFILE_ID = "aisparring.ranked_draft_profile.standard_1_2_2.v1"
DIRECT_PROFILE_ID = "aisparring.ranked_selection_profile.player_choice.v1"
DIRECT_COMMITMENT_DOMAIN = "aisparring.ranked_selection_commitment.v1"
MAX_SELECTION_OPTIONS = 128

# Named local draft profile. The user's supplied middle counts (1, 2, 2) are the
# released profile; only the four stages below exist and no private queue weight
# or current Discord distribution is claimed.
PROFILE_STAGE_COUNTS = (1, 2, 2, 1)
PROFILE_STAGE_OPS = ("ban", "ban", "ban", "select")
# The three ban stages remove five combinations, so the final select chooses one
# of the four remaining; the public pool is therefore nine distinct combinations.
POOL_SIZE = 9

MAX_DECK_REPEAT = 2
MAX_STAKE_REPEAT = 3
MAX_POOL_OPTIONS = 64
MAX_OPTION_ID = 48
MAX_KEY = 32
MAX_STEPS = 4
MAX_REQUEST_ID = 64
MAX_REPLAY = 64
TTL_SECONDS = 1800

OPERATIONS = ("ban", "select")
ACTORS = ("human", "ai")

_STAKE_FIRST_KEY = "white"
_OPTION_ID_SEP = "~"
_KEY_OK = frozenset("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")

# The AI's public, seed-independent draft preference. Bans remove the least
# preferred remaining combinations; the final pick takes the most preferred. A
# deck later in this list is less preferred; stakes are ranked by their actual
# index (lower is preferred). Unknown decks fall back to lexicographic order,
# so the preference is always total and deterministic over the public pool.
AI_DECK_PREFERENCE = (
    "red",
    "blue",
    "yellow",
    "green",
    "black",
    "magic",
    "nebula",
    "ghost",
    "abandoned",
    "checkered",
    "zodiac",
    "painted",
    "anaglyph",
    "plasma",
    "erratic",
)


class DraftError(Exception):
    """Bounded, non-leaking draft failure."""

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


def _key_ok(value) -> bool:
    if not isinstance(value, str) or not (1 <= len(value) <= MAX_KEY):
        return False
    return all(ch in _KEY_OK for ch in value)


def option_id_for(deck_key: str, stake_key: str) -> str:
    return deck_key + _OPTION_ID_SEP + stake_key


def option_id_ok(value) -> bool:
    if not isinstance(value, str) or not (1 <= len(value) <= MAX_OPTION_ID):
        return False
    if value.count(_OPTION_ID_SEP) != 1:
        return False
    deck, stake = value.split(_OPTION_ID_SEP)
    return _key_ok(deck) and _key_ok(stake)


# ---------------------------------------------------------------------------
# Pool construction
# ---------------------------------------------------------------------------

def build_draft_pool(catalog) -> dict:
    """Build the explicit 9-combination pool from the measured catalog.

    Returns ``{"ok", "problems", "pool", "white_option"}``. The pool is unique,
    caps each deck at ``MAX_DECK_REPEAT`` and each stake at ``MAX_STAKE_REPEAT``,
    and always contains a White-stake option (the catalog must declare the named
    ``white`` stake). A catalog that cannot supply the profile fails closed; no
    count or index is guessed.
    """
    problems: list[str] = []
    if not isinstance(catalog, Mapping):
        return {"ok": False, "problems": ["ranked_draft_catalog_missing"]}
    decks = catalog.get("decks")
    stakes = catalog.get("stakes")
    if not isinstance(decks, Mapping) or not isinstance(stakes, Mapping):
        return {"ok": False, "problems": ["ranked_draft_catalog_invalid"]}
    if not decks or not stakes:
        return {"ok": False, "problems": ["ranked_draft_catalog_invalid"]}

    deck_entries: dict = {}
    for key, entry in decks.items():
        if not _key_ok(key) or not isinstance(entry, Mapping):
            problems.append("ranked_draft_deck_invalid")
            continue
        if not isinstance(entry.get("center_key"), str) or not isinstance(entry.get("name"), str):
            problems.append("ranked_draft_deck_invalid")
            continue
        deck_entries[key] = {"center_key": entry["center_key"], "name": entry["name"]}
    stake_entries: dict = {}
    for key, entry in stakes.items():
        if not _key_ok(key) or not isinstance(entry, Mapping):
            problems.append("ranked_draft_stake_invalid")
            continue
        index = entry.get("index")
        if isinstance(index, bool) or not isinstance(index, int) or index < 1 or index > MAX_STAKE_INDEX:
            problems.append("ranked_draft_stake_invalid")
            continue
        stake_entries[key] = {"index": index}
    if problems:
        return {"ok": False, "problems": sorted(set(problems))}
    if _STAKE_FIRST_KEY not in stake_entries:
        return {"ok": False, "problems": ["ranked_white_stake_missing"]}

    ordered_decks = sorted(deck_entries.keys(), key=lambda k: k.encode("utf-8"))
    ordered_stakes = [_STAKE_FIRST_KEY] + sorted(
        (k for k in stake_entries if k != _STAKE_FIRST_KEY),
        key=lambda k: (stake_entries[k]["index"], k.encode("utf-8")),
    )

    deck_count: dict = {}
    pool: list = []
    # For each stake, start the deck scan at a rotated offset so the two
    # repetition caps (`MAX_DECK_REPEAT`, `MAX_STAKE_REPEAT`) are balanced across
    # the pool rather than exhausting the first stakes' decks. This is a
    # deterministic, catalog-only construction: nothing is guessed.
    for stake_offset, stake_key in enumerate(ordered_stakes):
        if len(pool) >= POOL_SIZE:
            break
        added = 0
        for step in range(len(ordered_decks)):
            if len(pool) >= POOL_SIZE or added >= MAX_STAKE_REPEAT:
                break
            deck_key = ordered_decks[(stake_offset + step) % len(ordered_decks)]
            if deck_count.get(deck_key, 0) >= MAX_DECK_REPEAT:
                continue
            pool.append(option_id_for(deck_key, stake_key))
            deck_count[deck_key] = deck_count.get(deck_key, 0) + 1
            added += 1
    if len(pool) != POOL_SIZE:
        return {"ok": False, "problems": ["ranked_pool_insufficient"]}
    if len(set(pool)) != POOL_SIZE:
        return {"ok": False, "problems": ["ranked_pool_duplicate"]}
    white_option = next((opt for opt in pool if opt.split(_OPTION_ID_SEP)[1] == _STAKE_FIRST_KEY), None)
    if white_option is None:
        return {"ok": False, "problems": ["ranked_white_stake_missing"]}
    return {
        "ok": True,
        "problems": [],
        "pool": pool,
        "white_option": white_option,
        "deck_entries": deck_entries,
        "stake_entries": stake_entries,
    }


def build_selection_pool(catalog) -> dict:
    """All measured deck/stake combinations, bounded and seed-independent."""
    if not isinstance(catalog, Mapping):
        return {"ok": False, "problems": ["ranked_draft_catalog_missing"]}
    decks, stakes = catalog.get("decks"), catalog.get("stakes")
    if not isinstance(decks, Mapping) or not isinstance(stakes, Mapping) or not decks or not stakes:
        return {"ok": False, "problems": ["ranked_draft_catalog_invalid"]}
    if len(decks) * len(stakes) > MAX_SELECTION_OPTIONS:
        return {"ok": False, "problems": ["ranked_draft_pool_size"]}
    pool = []
    for deck in sorted(decks, key=lambda k: (k != "red", str(k))):
        for stake in sorted(stakes, key=lambda k: (str(k) != "white", str(k))):
            if not _key_ok(deck) or not _key_ok(stake):
                return {"ok": False, "problems": ["ranked_draft_catalog_invalid"]}
            option = option_id_for(deck, stake)
            try:
                selection = selection_for_option(catalog, option)
            except DraftError as error:
                return {"ok": False, "problems": [error.code]}
            if not (1 <= selection["stake_index"] <= MAX_STAKE_INDEX):
                return {"ok": False, "problems": ["ranked_draft_catalog_invalid"]}
            pool.append(option)
    return {"ok": True, "pool": pool}


def validate_selection_transcript(pool, first_actor, transcript) -> dict:
    if not 1 <= len(pool) <= MAX_SELECTION_OPTIONS or len(set(pool)) != len(pool):
        return {"ok": False, "problems": ["ranked_draft_pool_size"]}
    if first_actor != "human":
        return {"ok": False, "problems": ["ranked_draft_first_actor_invalid"]}
    if not isinstance(transcript, (list, tuple)) or len(transcript) != 1:
        return {"ok": False, "problems": ["ranked_draft_transcript_shape"]}
    step = transcript[0]
    if not isinstance(step, Mapping) or step.get("actor") != "human" or step.get("operation") != "select":
        return {"ok": False, "problems": ["ranked_draft_turn"]}
    options = step.get("option_ids")
    if not isinstance(options, (list, tuple)) or len(options) != 1 or options[0] not in pool:
        return {"ok": False, "problems": ["ranked_draft_option_unavailable"]}
    return {"ok": True, "final": options[0]}


def selection_for_option(catalog, option_id) -> dict:
    """Resolve one option id into the canonical selection binding."""
    if not option_id_ok(option_id):
        raise DraftError("ranked_draft_option_invalid")
    decks = catalog.get("decks") if isinstance(catalog, Mapping) else None
    stakes = catalog.get("stakes") if isinstance(catalog, Mapping) else None
    if not isinstance(decks, Mapping) or not isinstance(stakes, Mapping):
        raise DraftError("ranked_draft_catalog_invalid")
    deck_key, stake_key = option_id.split(_OPTION_ID_SEP)
    deck = decks.get(deck_key)
    stake = stakes.get(stake_key)
    if not isinstance(deck, Mapping) or not isinstance(stake, Mapping):
        raise DraftError("ranked_draft_option_unknown")
    back_key = deck.get("center_key")
    back_name = deck.get("name")
    stake_index = stake.get("index")
    if not isinstance(back_key, str) or not isinstance(back_name, str):
        raise DraftError("ranked_draft_catalog_invalid")
    if isinstance(stake_index, bool) or not isinstance(stake_index, int):
        raise DraftError("ranked_draft_catalog_invalid")
    return {
        "schema": "aisparring.ranked_selection.v1",
        "deck_key": deck_key,
        "back_key": back_key,
        "back_name": back_name,
        "stake_key": stake_key,
        "stake_index": stake_index,
    }


# ---------------------------------------------------------------------------
# Transcript legality (shared with the Lua runtime roles)
# ---------------------------------------------------------------------------

def stage_plan(first_actor: str) -> list:
    """Ordered ``(actor, operation, count)`` stages for a first actor."""
    if first_actor not in ACTORS:
        raise DraftError("ranked_draft_first_actor_invalid")
    second = "ai" if first_actor == "human" else "human"
    plan = []
    for stage, (count, op) in enumerate(zip(PROFILE_STAGE_COUNTS, PROFILE_STAGE_OPS)):
        actor = first_actor if stage % 2 == 0 else second
        plan.append({"stage": stage, "actor": actor, "operation": op, "count": count})
    return plan


def validate_transcript(pool, first_actor, transcript) -> dict:
    """Independently validate a public transcript against the profile.

    Returns ``{"ok", "problems", "final", "selection_options"}``. The transcript
    must be exactly the four profile stages (actor, operation and count), every
    option must be still available at that step, options within a step must be
    distinct, and the final select must name a single remaining option.
    """
    problems: list[str] = []
    if not isinstance(pool, (list, tuple)) or len(pool) != POOL_SIZE:
        return {"ok": False, "problems": ["ranked_draft_pool_size"]}
    if len(set(pool)) != POOL_SIZE or not all(option_id_ok(opt) for opt in pool):
        return {"ok": False, "problems": ["ranked_draft_pool_invalid"]}
    plan = stage_plan(first_actor)
    if not isinstance(transcript, (list, tuple)) or len(transcript) != len(plan):
        return {"ok": False, "problems": ["ranked_draft_transcript_shape"]}
    remaining = list(pool)
    final = None
    for index, step in enumerate(transcript):
        expected = plan[index]
        if not isinstance(step, Mapping) or set(step.keys()) != {"actor", "operation", "option_ids"}:
            problems.append("ranked_draft_transcript_shape")
            break
        if step.get("actor") != expected["actor"]:
            problems.append("ranked_draft_turn")
        if step.get("operation") != expected["operation"]:
            problems.append("ranked_draft_operation")
        options = step.get("option_ids")
        if not isinstance(options, (list, tuple)) or len(options) != expected["count"]:
            problems.append("ranked_draft_count")
            break
        seen: set = set()
        for option in options:
            if not option_id_ok(option) or option in seen:
                problems.append("ranked_draft_option_invalid")
                continue
            seen.add(option)
            if option not in remaining:
                problems.append("ranked_draft_option_unavailable")
        if problems:
            break
        if expected["operation"] == "select":
            final = options[0]
        else:
            remaining = [item for item in remaining if item not in seen]
    if problems:
        return {"ok": False, "problems": sorted(set(problems))}
    if final is None:
        return {"ok": False, "problems": ["ranked_draft_transcript_shape"]}
    return {"ok": True, "problems": [], "final": final, "selection_options": remaining}


# ---------------------------------------------------------------------------
# Dedicated commitment
# ---------------------------------------------------------------------------

def _canonical_component(value: str) -> bool:
    if not isinstance(value, str) or not value:
        return False
    for ch in value:
        code = ord(ch)
        if code < 0x20 or code == 0x7F or ch in ("|", "=", ":", ";", ",", "+"):
            return False
    return True


def commitment_canonical(profile_id: str, first_actor: str, pool, transcript, final: str) -> str:
    """Domain-separated canonical string for the dedicated draft commitment."""
    if profile_id not in (DRAFT_PROFILE_ID, DIRECT_PROFILE_ID):
        raise DraftError("ranked_draft_profile_invalid")
    if not _canonical_component(first_actor) or not _canonical_component(final):
        raise DraftError("ranked_draft_canonical_invalid")
    if not isinstance(pool, (list, tuple)):
        raise DraftError("ranked_draft_canonical_invalid")
    pool_tokens = []
    for option in pool:
        if not option_id_ok(option):
            raise DraftError("ranked_draft_canonical_invalid")
        pool_tokens.append(option)
    if not isinstance(transcript, (list, tuple)):
        raise DraftError("ranked_draft_canonical_invalid")
    step_tokens = []
    for step in transcript:
        if not isinstance(step, Mapping):
            raise DraftError("ranked_draft_canonical_invalid")
        actor = step.get("actor")
        operation = step.get("operation")
        options = step.get("option_ids")
        if actor not in ACTORS or operation not in OPERATIONS:
            raise DraftError("ranked_draft_canonical_invalid")
        if not isinstance(options, (list, tuple)) or not options:
            raise DraftError("ranked_draft_canonical_invalid")
        for option in options:
            if not option_id_ok(option):
                raise DraftError("ranked_draft_canonical_invalid")
        step_tokens.append(actor + ":" + operation + ":" + "+".join(options))
    parts = [
        DIRECT_COMMITMENT_DOMAIN if profile_id == DIRECT_PROFILE_ID else DRAFT_COMMITMENT_DOMAIN,
        "profile=" + profile_id,
        "first=" + first_actor,
        "pool=" + ",".join(pool_tokens),
        "transcript=" + ";".join(step_tokens),
        "final=" + final,
    ]
    canonical = "|".join(parts)
    if len(canonical.encode("utf-8")) > 8192:
        raise DraftError("ranked_draft_canonical_too_large")
    return canonical


def commitment_digest(profile_id: str, first_actor: str, pool, transcript, final: str) -> str:
    canonical = commitment_canonical(profile_id, first_actor, pool, transcript, final)
    return fnv1a32_hex(canonical)


def commitment_from_public(public) -> dict:
    """Validate a public commitment mapping and derive its digest.

    Returns ``{"ok", "problems", "digest", "final"}``. This is the exact bounded
    public transcript both runtime roles independently validate.
    """
    problems: list[str] = []
    if not isinstance(public, Mapping):
        return {"ok": False, "problems": ["ranked_draft_commitment_missing"]}
    if public.get("schema") != DRAFT_SCHEMA:
        return {"ok": False, "problems": ["ranked_draft_commitment_schema"]}
    if public.get("profile_id") not in (DRAFT_PROFILE_ID, DIRECT_PROFILE_ID):
        problems.append("ranked_draft_profile_invalid")
    first_actor = public.get("first_actor")
    if first_actor not in ACTORS:
        problems.append("ranked_draft_first_actor_invalid")
    pool = public.get("pool")
    if not isinstance(pool, (list, tuple)) or not all(option_id_ok(opt) for opt in pool):
        problems.append("ranked_draft_pool_invalid")
    transcript = public.get("transcript")
    final = public.get("final")
    if problems:
        return {"ok": False, "problems": sorted(set(problems))}
    validator = validate_selection_transcript if public["profile_id"] == DIRECT_PROFILE_ID else validate_transcript
    verdict = validator(pool, first_actor, transcript)
    if not verdict.get("ok"):
        return {"ok": False, "problems": verdict.get("problems") or ["ranked_draft_transcript_invalid"]}
    if final != verdict["final"]:
        return {"ok": False, "problems": ["ranked_draft_final_mismatch"]}
    try:
        digest = commitment_digest(public["profile_id"], first_actor, pool, transcript, final)
    except DraftError as error:
        return {"ok": False, "problems": [error.code]}
    return {"ok": True, "problems": [], "digest": digest, "final": final}


# ---------------------------------------------------------------------------
# State machine
# ---------------------------------------------------------------------------

class RankedDraft:
    """Bounded host-owned draft. One instance == one named draft_id."""

    profile_id = DRAFT_PROFILE_ID
    pool_builder = staticmethod(build_draft_pool)

    def __init__(
        self,
        catalog,
        bound_settings: Mapping,
        generation: Optional[str],
        *,
        first_actor: Optional[str] = None,
        draft_id: Optional[str] = None,
        clock=time.monotonic,
    ) -> None:
        built = self.pool_builder(catalog)
        if not built.get("ok"):
            raise DraftError((built.get("problems") or ["ranked_draft_catalog_invalid"])[0])
        self.catalog = {"decks": dict(catalog["decks"]), "stakes": dict(catalog["stakes"])}
        self.pool = list(built["pool"])
        self.draft_id = draft_id or ("draft-" + secrets.token_hex(8))
        # OS randomness, independent of any gameplay/gauntlet seed.
        self.first_actor = first_actor if first_actor in ACTORS else ("human" if secrets.randbits(1) else "ai")
        self.revision = 0
        self.status = "active"
        self.transcript: list = []
        self.remaining = list(self.pool)
        self.banned: list = []
        self.final: Optional[str] = None
        self.selection: Optional[dict] = None
        self.snapshot_commitment: Optional[dict] = None
        self.bound_settings = dict(bound_settings or {})
        self.generation = generation
        self.created_at = float(clock())
        self._clock = clock
        self._replay: dict = {}
        self._replay_order: list = []
        self.consumed = False
        self.cancelled = False

    # -- public view --------------------------------------------------------

    def _plan_stage(self):
        plan = stage_plan(self.first_actor)
        if len(self.transcript) >= len(plan):
            return None
        return plan[len(self.transcript)]

    def current_actor(self) -> Optional[str]:
        stage = self._plan_stage()
        return stage["actor"] if stage else None

    def current_operation(self) -> Optional[str]:
        stage = self._plan_stage()
        return stage["operation"] if stage else None

    def required_count(self) -> Optional[int]:
        stage = self._plan_stage()
        return stage["count"] if stage else None

    def expired(self) -> bool:
        return (self._clock() - self.created_at) > TTL_SECONDS

    def _option_view(self, option_id):
        deck_key, stake_key = option_id.split(_OPTION_ID_SEP)
        deck = self.catalog["decks"].get(deck_key, {})
        stake = self.catalog["stakes"].get(stake_key, {})
        return {
            "option_id": option_id,
            "deck_key": deck_key,
            "deck_name": deck.get("name"),
            "stake_key": stake_key,
            "stake_index": stake.get("index"),
        }

    def public_state(self) -> dict:
        second = "ai" if self.first_actor == "human" else "human"
        state = {
            "schema": DRAFT_SCHEMA,
            "draft_id": self.draft_id,
            "profile_id": self.profile_id,
            "status": "expired" if (self.status == "active" and self.expired()) else self.status,
            "revision": self.revision,
            "first_actor": self.first_actor,
            "turn_order": [self.first_actor, second],
            "current_actor": self.current_actor() if self.status == "active" else None,
            "operation": self.current_operation() if self.status == "active" else None,
            "required_count": self.required_count() if self.status == "active" else None,
            "pool": [self._option_view(opt) for opt in self.pool],
            "remaining": list(self.remaining),
            "banned": list(self.banned),
            "transcript": [
                {"actor": step["actor"], "operation": step["operation"], "option_ids": list(step["option_ids"])}
                for step in self.transcript
            ],
            "final": self.final,
            "final_selection": dict(self.selection) if self.selection else None,
        }
        if self.final is not None:
            state["commitment_digest"] = self.commitment["digest"]
        return state

    # -- commitment ---------------------------------------------------------

    @property
    def commitment(self) -> dict:
        verdict = commitment_from_public(
            {
                "schema": DRAFT_SCHEMA,
                "profile_id": self.profile_id,
                "first_actor": self.first_actor,
                "pool": list(self.pool),
                "transcript": list(self.transcript),
                "final": self.final,
            }
        )
        if not verdict.get("ok"):
            raise DraftError((verdict.get("problems") or ["ranked_draft_transcript_invalid"])[0])
        return {"digest": verdict["digest"], "final": verdict["final"]}

    def public_commitment(self) -> dict:
        digest = self.commitment["digest"]
        return {
            "schema": DRAFT_SCHEMA,
            "profile_id": self.profile_id,
            "first_actor": self.first_actor,
            "pool": list(self.pool),
            "transcript": [
                {"actor": step["actor"], "operation": step["operation"], "option_ids": list(step["option_ids"])}
                for step in self.transcript
            ],
            "final": self.final,
            "digest": digest,
        }

    # -- AI preference ------------------------------------------------------

    def _preference(self, option_id):
        deck_key, stake_key = option_id.split(_OPTION_ID_SEP)
        deck_rank = AI_DECK_PREFERENCE.index(deck_key) if deck_key in AI_DECK_PREFERENCE else len(AI_DECK_PREFERENCE)
        stake_index = self.catalog["stakes"].get(stake_key, {}).get("index", MAX_STAKE_INDEX + 1)
        return (deck_rank, stake_index, deck_key.encode("utf-8"), stake_key.encode("utf-8"))

    def ai_option_ids(self):
        """The AI's public choice for its current turn (seed-independent)."""
        stage = self._plan_stage()
        if stage is None or stage["actor"] != "ai":
            return None
        ranked = sorted(self.remaining, key=self._preference)
        if stage["operation"] == "select":
            return ranked[:1]
        # Ban the least-preferred remaining combinations.
        return ranked[len(ranked) - stage["count"]:]

    # -- actions ------------------------------------------------------------

    def _replay_key(self, request_id):
        return request_id

    def _record_replay(self, request_id, fingerprint, response):
        self._replay[request_id] = (fingerprint, response)
        self._replay_order.append(request_id)
        while len(self._replay_order) > MAX_REPLAY:
            oldest = self._replay_order.pop(0)
            self._replay.pop(oldest, None)

    def _action_fingerprint(self, request_id, expected_revision, operation, option_ids):
        return (
            request_id,
            expected_revision,
            operation,
            tuple(option_ids),
        )

    def apply(self, actor: str, request_id: str, expected_revision, operation, option_ids) -> dict:
        """Commit one action. Returns ``{"ok", "code", "status", "state"}``.

        Same ``request_id`` replay returns the stored outcome verbatim without a
        second transition; reusing a request_id for a different action is refused.
        """
        if not isinstance(request_id, str) or not (1 <= len(request_id) <= MAX_REQUEST_ID):
            return {"ok": False, "code": "ranked_draft_request_id_invalid"}
        if isinstance(expected_revision, bool) or not isinstance(expected_revision, int):
            return {"ok": False, "code": "ranked_draft_revision_invalid"}
        if not isinstance(operation, str) or operation not in OPERATIONS:
            return {"ok": False, "code": "ranked_draft_operation_invalid"}
        if not isinstance(option_ids, (list, tuple)):
            return {"ok": False, "code": "ranked_draft_options_invalid"}
        for option in option_ids:
            if not option_id_ok(option):
                return {"ok": False, "code": "ranked_draft_options_invalid"}
        fingerprint = self._action_fingerprint(request_id, expected_revision, operation, list(option_ids))
        if request_id in self._replay:
            stored_fingerprint, response = self._replay[request_id]
            if stored_fingerprint != fingerprint:
                return {"ok": False, "code": "ranked_draft_request_conflict"}
            return {"ok": True, "code": "ranked_draft_replay", "status": response["status"], "state": response["state"]}
        if self.cancelled:
            return {"ok": False, "code": "ranked_draft_cancelled"}
        if self.status == "completed":
            return {"ok": False, "code": "ranked_draft_completed"}
        if self.expired():
            self.status = "expired"
            return {"ok": False, "code": "ranked_draft_expired"}
        stage = self._plan_stage()
        if stage is None:
            return {"ok": False, "code": "ranked_draft_completed"}
        if actor != stage["actor"]:
            return {"ok": False, "code": "ranked_draft_out_of_turn"}
        if operation != stage["operation"]:
            return {"ok": False, "code": "ranked_draft_operation_invalid"}
        if expected_revision != self.revision:
            return {"ok": False, "code": "ranked_draft_stale", "revision": self.revision}
        if len(option_ids) != stage["count"]:
            return {"ok": False, "code": "ranked_draft_count_invalid"}
        if len(set(option_ids)) != len(option_ids):
            return {"ok": False, "code": "ranked_draft_duplicate_option"}
        for option in option_ids:
            if option not in self.remaining:
                return {"ok": False, "code": "ranked_draft_option_unavailable"}

        if operation == "select":
            self.final = option_ids[0]
            self.selection = selection_for_option(self.catalog, self.final)
        else:
            for option in option_ids:
                self.remaining.remove(option)
                self.banned.append(option)
        self.transcript.append(
            {"actor": actor, "operation": operation, "option_ids": list(option_ids)}
        )
        self.revision += 1
        if self.final is not None:
            self.status = "completed"
        state = self.public_state()
        self._record_replay(request_id, fingerprint, {"status": self.status, "state": state})
        return {"ok": True, "code": "ranked_draft_ok", "status": self.status, "state": state}

    def auto_ai(self, ai_request_prefix="ai") -> None:
        """Execute AI turns until it is the human's turn or the draft completes."""
        guard = 0
        while self.status == "active" and not self.cancelled and self.current_actor() == "ai":
            guard += 1
            if guard > MAX_STEPS:
                raise DraftError("ranked_draft_ai_loop")
            options = self.ai_option_ids()
            if not options:
                raise DraftError("ranked_draft_ai_stuck")
            request_id = "%s-%d-%d" % (ai_request_prefix, self.revision, guard)
            verdict = self.apply("ai", request_id, self.revision, self.current_operation(), options)
            if not verdict.get("ok"):
                raise DraftError(verdict.get("code", "ranked_draft_ai_failed"))

    def cancel(self) -> dict:
        """Void an unconsumed draft (active *or* completed).

        The architecture explicitly voids a completed UNCONSUMED draft on
        cancellation. A consumed draft is owned by a launch and can never be
        cancelled. Cancelling an already-cancelled draft is honest idempotence.
        """
        if self.consumed:
            return {"ok": False, "code": "ranked_draft_consumed"}
        if self.cancelled:
            return {"ok": True, "code": "ranked_draft_cancelled"}
        self.cancelled = True
        self.status = "cancelled"
        return {"ok": True, "code": "ranked_draft_cancelled"}

    def mark_consumed(self) -> bool:
        """Consume a completed, uncancelled, unexpired draft exactly once.

        A cancelled or expired draft can never be consumed (and therefore never
        launched); the monotonic TTL is never extended by a request.
        """
        if self.cancelled:
            return False
        if self.expired():
            self.status = "expired"
            return False
        if self.status != "completed" or self.consumed:
            return False
        self.consumed = True
        return True

    def settings_match(self, settings: Mapping, generation: Optional[str]) -> bool:
        if self.generation != generation:
            return False
        if not isinstance(settings, Mapping):
            return False
        return dict(self.bound_settings) == dict(settings)


class RankedSelection(RankedDraft):
    """Player chooses one real combination; all launch guards remain shared."""

    profile_id = DIRECT_PROFILE_ID
    pool_builder = staticmethod(build_selection_pool)

    def __init__(self, catalog, bound_settings, generation, **kwargs):
        kwargs["first_actor"] = "human"
        super().__init__(catalog, bound_settings, generation, **kwargs)

    def _plan_stage(self):
        if self.transcript:
            return None
        return {"stage": 0, "actor": "human", "operation": "select", "count": 1}


__all__ = [
    "RankedSelection", "DIRECT_PROFILE_ID", "DIRECT_COMMITMENT_DOMAIN",
    "ACTORS",
    "AI_DECK_PREFERENCE",
    "DRAFT_COMMITMENT_DOMAIN",
    "DRAFT_PROFILE_ID",
    "DRAFT_SCHEMA",
    "DraftError",
    "MAX_DECK_REPEAT",
    "MAX_REPLAY",
    "MAX_STAKE_REPEAT",
    "OPERATIONS",
    "POOL_SIZE",
    "PROFILE_STAGE_COUNTS",
    "PROFILE_STAGE_OPS",
    "RankedDraft",
    "TTL_SECONDS",
    "build_draft_pool",
    "commitment_canonical",
    "commitment_digest",
    "commitment_from_public",
    "option_id_for",
    "option_id_ok",
    "selection_for_option",
    "stage_plan",
    "validate_transcript",
]
