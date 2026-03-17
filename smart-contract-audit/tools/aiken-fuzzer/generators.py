"""
generators.py — Type-specific random value generators for Aiken/Plutus types.

Each generator produces Python values that represent Plutus data, which can
then be serialized to JSON (for off-chain tooling) or formatted as Aiken
literal expressions (for embedded test generation).

Plutus data model:
  - Int    → Python int
  - Bytes  → Python bytes (hex-encoded when serialized)
  - List   → Python list
  - Constructor(index, fields) → dict {"constructor": int, "fields": [...]}
"""

from __future__ import annotations
import random
import os
from typing import Any, Optional

from aiken_types import (
    AikenType, IntType, BytesType, ListType, SumType,
    ConstructorVariant, UnknownType,
)


# ---------------------------------------------------------------------------
# Constants — boundary values
# ---------------------------------------------------------------------------

INT_ZERO = 0
INT_ONE = 1
INT_NEG_ONE = -1
INT_MAX_SMALL = 2**31 - 1          # 2147483647
INT_MIN_SMALL = -(2**31)           # -2147483648
INT_MAX_LARGE = 2**63 - 1          # 9223372036854775807
INT_MIN_LARGE = -(2**63)           # -9223372036854775808

# Common Cardano/UTxO domain constants
POSIX_MIN = 1_000_000_000_000      # ~2001
POSIX_NOW = 1_742_000_000_000      # ~2025
POSIX_MAX = 9_999_999_999_999      # ~2286

LOVELACE_MIN = 1_000_000           # 1 ADA (min UTxO)
LOVELACE_MAX = 45_000_000_000_000  # ~45B ADA (total supply)

# Cardano key hash is 28 bytes (224 bits)
KEY_HASH_LEN = 28


# ---------------------------------------------------------------------------
# Primitive generators
# ---------------------------------------------------------------------------

class IntGenerator:
    """Generate integers: random, boundary, domain-specific."""

    EDGE_CASES = [
        INT_ZERO,
        INT_ONE,
        INT_NEG_ONE,
        INT_MAX_SMALL,
        INT_MIN_SMALL,
        INT_MAX_LARGE,
        INT_MIN_LARGE,
        LOVELACE_MIN,
        LOVELACE_MAX,
        POSIX_MIN,
        POSIX_NOW,
        POSIX_MAX,
    ]

    def __init__(self, rng: random.Random):
        self.rng = rng

    def random(self, lo: int = INT_MIN_LARGE, hi: int = INT_MAX_LARGE) -> int:
        return self.rng.randint(lo, hi)

    def random_positive(self) -> int:
        return self.rng.randint(1, INT_MAX_LARGE)

    def random_lovelace(self) -> int:
        return self.rng.randint(LOVELACE_MIN, LOVELACE_MAX)

    def random_posix(self) -> int:
        return self.rng.randint(POSIX_MIN, POSIX_MAX)

    def edge_cases(self) -> list[int]:
        return list(self.EDGE_CASES)

    def sample(self, mode: str = "random") -> int:
        if mode == "random":
            return self.random()
        elif mode == "positive":
            return self.random_positive()
        elif mode == "lovelace":
            return self.random_lovelace()
        elif mode == "posix":
            return self.random_posix()
        elif mode == "zero":
            return 0
        elif mode == "negative":
            return self.random(INT_MIN_LARGE, -1)
        elif mode == "max":
            return INT_MAX_LARGE
        elif mode == "min":
            return INT_MIN_LARGE
        else:
            return self.random()


class BytesGenerator:
    """Generate byte arrays: empty, random, key hashes, too-short, too-long."""

    def __init__(self, rng: random.Random):
        self.rng = rng

    def random_bytes(self, length: int) -> bytes:
        return bytes(self.rng.getrandbits(8) for _ in range(length))

    def key_hash(self) -> bytes:
        """Valid 28-byte Cardano verification key hash."""
        return self.random_bytes(KEY_HASH_LEN)

    def policy_id(self) -> bytes:
        """Valid 28-byte policy ID."""
        return self.random_bytes(28)

    def empty(self) -> bytes:
        return b""

    def too_short(self, expected_len: int = KEY_HASH_LEN) -> bytes:
        """Generate a byte array shorter than expected."""
        short = max(0, expected_len - self.rng.randint(1, min(expected_len, 10)))
        return self.random_bytes(short)

    def too_long(self, expected_len: int = KEY_HASH_LEN) -> bytes:
        """Generate a byte array longer than expected."""
        extra = self.rng.randint(1, 32)
        return self.random_bytes(expected_len + extra)

    def random(self, max_len: int = 64) -> bytes:
        length = self.rng.randint(0, max_len)
        return self.random_bytes(length)

    def edge_cases(self) -> list[bytes]:
        return [
            b"",                              # empty
            self.random_bytes(1),             # single byte
            self.random_bytes(KEY_HASH_LEN),  # exact key hash size
            self.random_bytes(32),            # blake2b-256 hash size
            self.random_bytes(KEY_HASH_LEN - 1),  # too short for key hash
            self.random_bytes(KEY_HASH_LEN + 1),  # too long for key hash
            b"\x00" * KEY_HASH_LEN,           # all zeros
            b"\xff" * KEY_HASH_LEN,           # all ones
        ]

    def sample(self, mode: str = "random") -> bytes:
        if mode == "key_hash":
            return self.key_hash()
        elif mode == "policy_id":
            return self.policy_id()
        elif mode == "empty":
            return b""
        elif mode == "too_short":
            return self.too_short()
        elif mode == "too_long":
            return self.too_long()
        elif mode == "zeros":
            return b"\x00" * KEY_HASH_LEN
        else:
            return self.random()


class ListGenerator:
    """Generate lists: empty, single item, many items, with duplicates."""

    def __init__(self, rng: random.Random):
        self.rng = rng

    def empty(self) -> list:
        return []

    def single(self, item_factory) -> list:
        return [item_factory()]

    def many(self, item_factory, count: Optional[int] = None) -> list:
        n = count if count is not None else self.rng.randint(2, 10)
        return [item_factory() for _ in range(n)]

    def duplicates(self, item_factory, count: int = 3) -> list:
        """Duplicate entries — can trigger duplicate-recipient bugs."""
        item = item_factory()
        return [item] * count

    def edge_cases(self, item_factory) -> list[list]:
        return [
            [],                               # empty list
            self.single(item_factory),        # exactly 1
            self.many(item_factory, 2),       # exactly 2
            self.many(item_factory, 100),     # large list
            self.duplicates(item_factory, 2), # 2 duplicates
            self.duplicates(item_factory, 5), # 5 duplicates
        ]


class ConstructorGenerator:
    """Generate Plutus constructor data (tagged unions / sum types)."""

    def __init__(self, rng: random.Random, value_gen: "ValueGenerator"):
        self.rng = rng
        self.vgen = value_gen

    def valid_variant(self, sum_type: SumType, variant_index: Optional[int] = None) -> dict:
        """Generate a valid constructor — picks a real variant."""
        if not sum_type.variants:
            return {"constructor": 0, "fields": []}

        if variant_index is not None:
            idx = variant_index % len(sum_type.variants)
            variant = sum_type.variants[idx]
        else:
            variant = self.rng.choice(sum_type.variants)

        fields = [self.vgen.generate(f.field_type) for f in variant.fields]
        return {"constructor": variant.index, "fields": fields}

    def invalid_variant(self, sum_type: SumType) -> dict:
        """Generate a constructor with an index that doesn't exist."""
        valid_indices = {v.index for v in sum_type.variants}
        invalid_idx = max(valid_indices) + 1 + self.rng.randint(0, 100)
        # Generate random fields
        field_count = self.rng.randint(0, 3)
        fields = [self.rng.randint(0, 1000) for _ in range(field_count)]
        return {"constructor": invalid_idx, "fields": fields}

    def wrong_field_types(self, sum_type: SumType) -> dict:
        """
        Generate a valid variant index but with wrong field types.
        Picks a variant that has at least one field (so the wrong types are meaningful).
        Falls back to invalid_variant if all variants are unit (no fields).
        """
        if not sum_type.variants:
            return {"constructor": 0, "fields": ["wrong", "types"]}

        # Prefer variants with fields so we can inject wrong types
        variants_with_fields = [v for v in sum_type.variants if v.fields]
        if not variants_with_fields:
            # All unit variants — no fields to corrupt, generate invalid index instead
            return self.invalid_variant(sum_type)

        variant = self.rng.choice(variants_with_fields)
        # Deliberately put wrong types in fields
        wrong_fields = []
        for f in variant.fields:
            if isinstance(f.field_type, IntType):
                wrong_fields.append(b"this_should_be_int")  # bytes instead of int
            elif isinstance(f.field_type, BytesType):
                wrong_fields.append(-999)  # int instead of bytes
            else:
                wrong_fields.append(None)
        return {"constructor": variant.index, "fields": wrong_fields}


# ---------------------------------------------------------------------------
# Composite value generator (dispatches by type)
# ---------------------------------------------------------------------------

class ValueGenerator:
    """
    Top-level generator: given an AikenType, produces a random Python value.

    Output format uses a Plutus-compatible dict representation:
      - Int → int
      - Bytes → bytes
      - List → list of items
      - Constructor → {"constructor": N, "fields": [...]}
    """

    def __init__(self, seed: Optional[int] = None):
        self.rng = random.Random(seed)
        self.int_gen = IntGenerator(self.rng)
        self.bytes_gen = BytesGenerator(self.rng)
        self.list_gen = ListGenerator(self.rng)
        self.con_gen = ConstructorGenerator(self.rng, self)

    def generate(self, typ: Optional[AikenType], mode: str = "random") -> Any:
        """Generate a value for the given type."""
        if typ is None or isinstance(typ, UnknownType):
            return self._generate_unknown()

        if isinstance(typ, IntType):
            return self.int_gen.sample(mode)

        if isinstance(typ, BytesType):
            # Heuristic: most byte fields in Cardano are key hashes (28 bytes)
            return self.bytes_gen.sample("key_hash" if mode == "random" else mode)

        if isinstance(typ, ListType):
            def item_factory():
                return self.generate(typ.item_type)
            count = self.rng.randint(0, 5)
            return self.list_gen.many(item_factory, count)

        if isinstance(typ, SumType):
            return self.con_gen.valid_variant(typ)

        return self._generate_unknown()

    def generate_edge_cases(self, typ: Optional[AikenType]) -> list[Any]:
        """Generate all boundary/edge case values for the given type."""
        if typ is None or isinstance(typ, UnknownType):
            return [None, 0, "", b"", [], {}]

        if isinstance(typ, IntType):
            return self.int_gen.edge_cases()

        if isinstance(typ, BytesType):
            return self.bytes_gen.edge_cases()

        if isinstance(typ, ListType):
            def item_factory():
                return self.generate(typ.item_type)
            return self.list_gen.edge_cases(item_factory)

        if isinstance(typ, SumType):
            cases = []
            # Every valid variant
            for i, variant in enumerate(typ.variants):
                cases.append(self.con_gen.valid_variant(typ, i))
            # Invalid variants
            cases.append(self.con_gen.invalid_variant(typ))
            cases.append(self.con_gen.wrong_field_types(typ))
            return cases

        return [None]

    def _generate_unknown(self) -> Any:
        """Fallback: generate something vaguely data-like."""
        choice = self.rng.randint(0, 3)
        if choice == 0:
            return self.rng.randint(-1000, 1000)
        elif choice == 1:
            return self.bytes_gen.random(16)
        elif choice == 2:
            return []
        else:
            return {"constructor": 0, "fields": []}


# ---------------------------------------------------------------------------
# Serialization helpers
# ---------------------------------------------------------------------------

def to_json_value(val: Any) -> Any:
    """Convert generated value to JSON-serializable form (bytes → hex string)."""
    if isinstance(val, bytes):
        return {"bytes": val.hex()}
    elif isinstance(val, int):
        return {"int": val}
    elif isinstance(val, list):
        return {"list": [to_json_value(v) for v in val]}
    elif isinstance(val, dict) and "constructor" in val:
        return {
            "constructor": val["constructor"],
            "fields": [to_json_value(f) for f in val.get("fields", [])],
        }
    elif val is None:
        return {"constructor": 1, "fields": []}  # Plutus None/Nothing
    else:
        return val


def to_aiken_literal(val: Any, indent: int = 0) -> str:
    """
    Convert a generated value to an Aiken source literal for test embedding.
    This is approximate — suitable for generating test scaffolding.
    """
    pad = "  " * indent
    if isinstance(val, bytes):
        return f'#"{val.hex()}"'
    elif isinstance(val, int):
        return str(val)
    elif isinstance(val, list):
        if not val:
            return "[]"
        items = ", ".join(to_aiken_literal(v, indent) for v in val)
        return f"[{items}]"
    elif isinstance(val, dict) and "constructor" in val:
        idx = val["constructor"]
        fields = val.get("fields", [])
        if not fields:
            return f"<variant_{idx}>"
        fstr = ", ".join(to_aiken_literal(f, indent) for f in fields)
        return f"<variant_{idx}>({fstr})"
    return repr(val)


if __name__ == "__main__":
    # Quick demo
    gen = ValueGenerator(seed=42)
    from aiken_types import IntType, BytesType, SumType, ConstructorVariant, ConstructorField

    print("=== Integer edge cases ===")
    int_type = IntType()
    for v in gen.generate_edge_cases(int_type):
        print(f"  {v}")

    print("\n=== ByteArray edge cases ===")
    bytes_type = BytesType()
    for v in gen.generate_edge_cases(bytes_type):
        print(f"  {v.hex() if v else '(empty)'}")
