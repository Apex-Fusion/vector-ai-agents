"""
CBOR Parity Tests — verify that PyCardano PlutusData serialization matches
the encoding that Aiken's `cbor.serialise()` produces on-chain.

WHY THIS MATTERS:
    The NFT asset name is derived as `blake2b_256(cbor.serialise(OutputReference))`
    both on-chain (Aiken) and off-chain (Python). If the CBOR encodings differ,
    the off-chain SDK will derive a DIFFERENT NFT name than the on-chain validator
    expects, and every register transaction will fail.

HOW:
    Aiken uses standard Plutus CBOR encoding (CONSTR tags + indefinite-length arrays).
    We manually construct the expected CBOR bytes from the Plutus specification
    and compare against PyCardano's `to_cbor()` output.

    The definitive on-chain verification happens in Day 4's integration test,
    but these offline tests catch the most common encoding mismatches.
"""

import hashlib
import struct

import cbor2
import pytest

from vector_agent.plutus_data import (
    AgentDatum,
    BurnRedeemer,
    DeregisterRedeemer,
    OutputReference,
    RegisterRedeemer,
    UpdateRedeemer,
    VerificationKeyCredential,
    ScriptCredential,
)
from vector_agent.registry import _derive_nft_name
from pycardano.serialization import IndefiniteList


# ──────────────────────────────────────────────────────────────────────
# Plutus CBOR encoding reference
# ──────────────────────────────────────────────────────────────────────
#
# Plutus uses CBOR constructor tags with INDEFINITE-LENGTH arrays:
#   Constructor 0 → tag 121, fields in 0x9F ... 0xFF (indef array)
#   Constructor 1 → tag 122
#   ...
#   Constructor 6 → tag 127
#   Constructor 7+ → tag 1280 + (constructor - 7)
#
# Both Aiken and PyCardano follow this convention.


def _plutus_constr_tag(constr_id: int) -> int:
    """Calculate the CBOR tag number for a Plutus constructor index."""
    if constr_id <= 6:
        return 121 + constr_id
    return 1280 + (constr_id - 7)


def _encode_plutus_constr(constr_id: int, fields: list) -> bytes:
    """
    Manually encode a Plutus data constructor to CBOR matching
    PyCardano/Aiken convention:
      - Empty fields: definite-length empty array (0x80)
      - Non-empty fields: indefinite-length array (0x9F ... 0xFF)
    """
    tag = _plutus_constr_tag(constr_id)

    parts = bytearray()

    # Tag encoding (CBOR major type 6)
    if tag < 24:
        parts.append(0xC0 | tag)
    elif tag < 256:
        parts.extend([0xD8, tag])
    elif tag < 65536:
        parts.extend([0xD9])
        parts.extend(tag.to_bytes(2, "big"))

    if not fields:
        # Empty constructor: definite-length empty array
        parts.append(0x80)
    else:
        # Non-empty: indefinite-length array
        parts.append(0x9F)

        for field in fields:
            if isinstance(field, bytes):
                parts.extend(_encode_cbor_bytes(field))
            elif isinstance(field, int):
                parts.extend(_encode_cbor_int(field))
            elif isinstance(field, cbor2.CBORTag):
                parts.extend(_encode_plutus_cbor_tag(field))
            else:
                raise TypeError(f"Unsupported field type: {type(field)}")

        parts.append(0xFF)

    return bytes(parts)


def _encode_cbor_bytes(data: bytes) -> bytes:
    """CBOR encode a bytestring (major type 2)."""
    length = len(data)
    if length < 24:
        return bytes([0x40 | length]) + data
    elif length < 256:
        return bytes([0x58, length]) + data
    elif length < 65536:
        return bytes([0x59]) + length.to_bytes(2, "big") + data
    else:
        raise ValueError("Bytestring too long")


def _encode_cbor_int(value: int) -> bytes:
    """CBOR encode a non-negative integer (major type 0)."""
    if value < 0:
        raise ValueError("Negative integers not supported in this helper")
    if value < 24:
        return bytes([value])
    elif value < 256:
        return bytes([0x18, value])
    elif value < 65536:
        return bytes([0x19]) + value.to_bytes(2, "big")
    elif value < 2**32:
        return bytes([0x1A]) + value.to_bytes(4, "big")
    else:
        return bytes([0x1B]) + value.to_bytes(8, "big")


def _encode_plutus_cbor_tag(tag: cbor2.CBORTag) -> bytes:
    """Encode a CBORTag using indefinite-length arrays (Plutus convention)."""
    fields = tag.value if isinstance(tag.value, list) else [tag.value]
    return _encode_plutus_constr(tag.tag - 121, fields)


# ──────────────────────────────────────────────────────────────────────
# Tests: OutputReference CBOR encoding
# ──────────────────────────────────────────────────────────────────────


class TestOutputReferenceCBOR:
    """Verify OutputReference CBOR matches Plutus specification."""

    def test_constr_tag_is_121(self):
        """OutputReference uses constructor 0 → CBOR tag 121."""
        assert _plutus_constr_tag(0) == 121

    def test_simple_output_reference_encoding(self):
        """
        OutputReference { tx_id: 0xde*32, output_index: 0 }
        Expected CBOR: tag(121, indef[ 0xdede...de, 0 ])
        """
        tx_hash = b"\xde" * 32
        ref = OutputReference(transaction_id=tx_hash, output_index=0)

        pycardano_cbor = ref.to_cbor()
        expected_cbor = _encode_plutus_constr(0, [tx_hash, 0])

        assert pycardano_cbor == expected_cbor, (
            f"CBOR mismatch!\n"
            f"  PyCardano: {pycardano_cbor.hex()}\n"
            f"  Expected:  {expected_cbor.hex()}"
        )

    def test_nonzero_output_index_encoding(self):
        """OutputReference with output_index > 0."""
        tx_hash = b"\xab" * 32
        ref = OutputReference(transaction_id=tx_hash, output_index=42)

        pycardano_cbor = ref.to_cbor()
        expected_cbor = _encode_plutus_constr(0, [tx_hash, 42])

        assert pycardano_cbor == expected_cbor

    def test_large_output_index(self):
        """OutputReference with a large output_index (multi-byte CBOR int)."""
        tx_hash = b"\x01" * 32
        ref = OutputReference(transaction_id=tx_hash, output_index=256)

        pycardano_cbor = ref.to_cbor()
        expected_cbor = _encode_plutus_constr(0, [tx_hash, 256])

        assert pycardano_cbor == expected_cbor

    def test_all_zeros_tx_hash(self):
        """OutputReference with all-zero tx hash."""
        tx_hash = b"\x00" * 32
        ref = OutputReference(transaction_id=tx_hash, output_index=0)

        pycardano_cbor = ref.to_cbor()
        expected_cbor = _encode_plutus_constr(0, [tx_hash, 0])

        assert pycardano_cbor == expected_cbor


# ──────────────────────────────────────────────────────────────────────
# Tests: NFT name derivation consistency
# ──────────────────────────────────────────────────────────────────────


class TestNftNameDerivation:
    """Verify the full NFT name derivation pipeline."""

    def test_nft_name_from_known_cbor(self):
        """
        Given a known OutputReference, manually compute the expected NFT name
        and verify it matches _derive_nft_name().
        """
        tx_hash = b"\xde" * 32
        seed = OutputReference(transaction_id=tx_hash, output_index=0)

        # Step 1: CBOR encode
        cbor_bytes = seed.to_cbor()

        # Step 2: blake2b-256
        expected_name = hashlib.blake2b(cbor_bytes, digest_size=32).digest()

        # Step 3: Compare with _derive_nft_name
        actual_name = _derive_nft_name(seed)

        assert actual_name == expected_name

    def test_nft_name_matches_manual_plutus_cbor(self):
        """
        Build CBOR manually (Plutus spec with indef arrays) and verify the
        derived NFT name matches what _derive_nft_name() produces.

        This is the critical parity test: if PlutusData CBOR and manual
        Plutus CBOR produce the same bytes, the on-chain derivation will match.
        """
        tx_hash = b"\xde" * 32
        output_index = 0

        # Manual Plutus CBOR (with indefinite-length arrays)
        manual_cbor = _encode_plutus_constr(0, [tx_hash, output_index])

        # PyCardano PlutusData CBOR
        seed = OutputReference(transaction_id=tx_hash, output_index=output_index)
        pycardano_cbor = seed.to_cbor()

        # Both should produce the same bytes
        assert manual_cbor == pycardano_cbor, (
            f"CBOR mismatch!\n"
            f"  Manual:    {manual_cbor.hex()}\n"
            f"  PyCardano: {pycardano_cbor.hex()}"
        )

        # And therefore the same NFT name
        manual_name = hashlib.blake2b(manual_cbor, digest_size=32).digest()
        actual_name = _derive_nft_name(seed)

        assert actual_name == manual_name

    def test_different_indices_different_names(self):
        """Different output indices yield different NFT names (collision resistance)."""
        tx_hash = b"\xab" * 32
        names = set()
        for i in range(10):
            seed = OutputReference(transaction_id=tx_hash, output_index=i)
            name = _derive_nft_name(seed)
            names.add(name)
        assert len(names) == 10

    def test_different_tx_hashes_different_names(self):
        """Different tx hashes yield different NFT names."""
        names = set()
        for i in range(10):
            tx_hash = bytes([i]) + b"\x00" * 31
            seed = OutputReference(transaction_id=tx_hash, output_index=0)
            name = _derive_nft_name(seed)
            names.add(name)
        assert len(names) == 10


# ──────────────────────────────────────────────────────────────────────
# Tests: Credential CBOR encoding
# ──────────────────────────────────────────────────────────────────────


class TestCredentialCBOR:
    """Verify Credential CBOR matches Plutus specification."""

    def test_vkey_credential_encoding(self):
        """VerificationKeyCredential (constructor 0) encodes correctly."""
        vkh = b"\xab" * 28
        cred = VerificationKeyCredential(vkey_hash=vkh)

        pycardano_cbor = cred.to_cbor()
        expected_cbor = _encode_plutus_constr(0, [vkh])

        assert pycardano_cbor == expected_cbor

    def test_script_credential_encoding(self):
        """ScriptCredential (constructor 1) encodes correctly."""
        sh = b"\xcd" * 28
        cred = ScriptCredential(script_hash=sh)

        pycardano_cbor = cred.to_cbor()
        expected_cbor = _encode_plutus_constr(1, [sh])

        assert pycardano_cbor == expected_cbor


# ──────────────────────────────────────────────────────────────────────
# Tests: Redeemer CBOR encoding
# ──────────────────────────────────────────────────────────────────────


class TestRedeemerCBOR:
    """Verify redeemer CBOR matches Plutus specification."""

    def test_register_redeemer_encoding(self):
        """RegisterRedeemer (constructor 0) wraps an OutputReference."""
        tx_hash = b"\xde" * 32
        seed = OutputReference(transaction_id=tx_hash, output_index=0)
        redeemer = RegisterRedeemer(seed=seed)

        pycardano_cbor = redeemer.to_cbor()

        # Register = constr 0, field is OutputReference = constr 0
        # Nested: tag(121, indef[ tag(121, indef[ tx_hash, 0 ]) ])
        inner = _encode_plutus_constr(0, [tx_hash, 0])

        # Build outer manually: tag(121) + 0x9F + inner_bytes + 0xFF
        outer = bytearray()
        outer.extend([0xD8, 121])  # tag 121
        outer.append(0x9F)         # indef array start
        outer.extend(inner)        # nested OutputReference
        outer.append(0xFF)         # indef array end

        assert pycardano_cbor == bytes(outer), (
            f"CBOR mismatch!\n"
            f"  PyCardano: {pycardano_cbor.hex()}\n"
            f"  Expected:  {bytes(outer).hex()}"
        )

    def test_burn_redeemer_encoding(self):
        """BurnRedeemer (constructor 1) has no fields."""
        redeemer = BurnRedeemer()

        pycardano_cbor = redeemer.to_cbor()
        expected_cbor = _encode_plutus_constr(1, [])

        assert pycardano_cbor == expected_cbor

    def test_update_redeemer_encoding(self):
        """UpdateRedeemer (constructor 0) has no fields."""
        redeemer = UpdateRedeemer()

        pycardano_cbor = redeemer.to_cbor()
        expected_cbor = _encode_plutus_constr(0, [])

        assert pycardano_cbor == expected_cbor

    def test_deregister_redeemer_encoding(self):
        """DeregisterRedeemer (constructor 1) has no fields."""
        redeemer = DeregisterRedeemer()

        pycardano_cbor = redeemer.to_cbor()
        expected_cbor = _encode_plutus_constr(1, [])

        assert pycardano_cbor == expected_cbor


# ──────────────────────────────────────────────────────────────────────
# Tests: AgentDatum CBOR encoding
# ──────────────────────────────────────────────────────────────────────


class TestAgentDatumCBOR:
    """Verify AgentDatum CBOR structure follows Plutus conventions."""

    def test_datum_cbor_structure(self):
        """
        AgentDatum has 7 fields and is constructor 0.
        Verify the CBOR tag is 121 and the top-level structure is correct.
        """
        datum = AgentDatum(
            owner=VerificationKeyCredential(vkey_hash=b"\xab" * 28),
            name=b"TestBot",
            description=b"A test agent",
            capabilities=IndefiniteList([b"testing"]),
            framework=b"pytest",
            endpoint=b"https://example.com",
            registered_at=1710000000000,
        )

        cbor_bytes = datum.to_cbor()

        # Decode and verify structure
        decoded = cbor2.loads(cbor_bytes)
        assert isinstance(decoded, cbor2.CBORTag)
        assert decoded.tag == 121  # Constructor 0

        fields = decoded.value
        assert len(fields) == 7

        # Field 0: owner (VerificationKeyCredential = constr 0)
        assert isinstance(fields[0], cbor2.CBORTag)
        assert fields[0].tag == 121
        assert fields[0].value == [b"\xab" * 28]

        # Field 1: name
        assert fields[1] == b"TestBot"

        # Field 2: description
        assert fields[2] == b"A test agent"

        # Field 3: capabilities (list)
        assert b"testing" in list(fields[3])

        # Field 4: framework
        assert fields[4] == b"pytest"

        # Field 5: endpoint
        assert fields[5] == b"https://example.com"

        # Field 6: registered_at
        assert fields[6] == 1710000000000

    def test_datum_cbor_field_order_matches_aiken(self):
        """
        Aiken serializes struct fields in declaration order.
        Verify PyCardano produces the same field order.

        Aiken type order: owner, name, description, capabilities,
                          framework, endpoint, registered_at
        """
        vkh = b"\x11" * 28
        datum = AgentDatum(
            owner=VerificationKeyCredential(vkey_hash=vkh),
            name=b"Bot",
            description=b"desc",
            capabilities=IndefiniteList([]),
            framework=b"fw",
            endpoint=b"ep",
            registered_at=42,
        )

        cbor_bytes = datum.to_cbor()
        decoded = cbor2.loads(cbor_bytes)
        fields = decoded.value

        # Verify each field is in the expected position
        assert fields[0].value == [vkh]      # owner
        assert fields[1] == b"Bot"            # name
        assert fields[2] == b"desc"           # description
        # fields[3] = capabilities (empty list)
        assert fields[4] == b"fw"             # framework
        assert fields[5] == b"ep"             # endpoint
        assert fields[6] == 42                # registered_at
