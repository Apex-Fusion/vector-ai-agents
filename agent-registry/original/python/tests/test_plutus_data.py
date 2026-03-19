"""Tests for PlutusData type definitions and CBOR serialization."""

import pytest
from pycardano.serialization import IndefiniteList

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


SAMPLE_VKH = bytes.fromhex("ab" * 28)
SAMPLE_SCRIPT_HASH = bytes.fromhex("cd" * 28)
SAMPLE_TX_HASH = bytes.fromhex("de" * 32)


class TestCredentials:
    def test_vkey_credential_constr_id(self):
        cred = VerificationKeyCredential(vkey_hash=SAMPLE_VKH)
        assert cred.CONSTR_ID == 0

    def test_script_credential_constr_id(self):
        cred = ScriptCredential(script_hash=SAMPLE_SCRIPT_HASH)
        assert cred.CONSTR_ID == 1

    def test_vkey_credential_cbor_roundtrip(self):
        cred = VerificationKeyCredential(vkey_hash=SAMPLE_VKH)
        cbor = cred.to_cbor()
        restored = VerificationKeyCredential.from_cbor(cbor)
        assert restored.vkey_hash == SAMPLE_VKH

    def test_script_credential_cbor_roundtrip(self):
        cred = ScriptCredential(script_hash=SAMPLE_SCRIPT_HASH)
        cbor = cred.to_cbor()
        restored = ScriptCredential.from_cbor(cbor)
        assert restored.script_hash == SAMPLE_SCRIPT_HASH


class TestOutputReference:
    def test_constr_id(self):
        ref = OutputReference(transaction_id=SAMPLE_TX_HASH, output_index=0)
        assert ref.CONSTR_ID == 0

    def test_cbor_roundtrip(self):
        ref = OutputReference(transaction_id=SAMPLE_TX_HASH, output_index=42)
        cbor = ref.to_cbor()
        restored = OutputReference.from_cbor(cbor)
        assert restored.transaction_id == SAMPLE_TX_HASH
        assert restored.output_index == 42


class TestAgentDatum:
    def make_datum(self) -> AgentDatum:
        return AgentDatum(
            owner=VerificationKeyCredential(vkey_hash=SAMPLE_VKH),
            name=b"TestBot",
            description=b"A test agent for unit tests",
            capabilities=IndefiniteList([b"testing", b"research"]),
            framework=b"pytest",
            endpoint=b"https://example.com/agent",
            registered_at=1710000000000,
        )

    def test_constr_id(self):
        datum = self.make_datum()
        assert datum.CONSTR_ID == 0

    def test_cbor_roundtrip(self):
        datum = self.make_datum()
        cbor = datum.to_cbor()
        restored = AgentDatum.from_cbor(cbor)
        assert restored.name == b"TestBot"
        assert restored.description == b"A test agent for unit tests"
        assert restored.framework == b"pytest"
        assert restored.endpoint == b"https://example.com/agent"
        assert restored.registered_at == 1710000000000

    def test_datum_owner_is_vkey_credential(self):
        datum = self.make_datum()
        assert isinstance(datum.owner, VerificationKeyCredential)
        assert datum.owner.vkey_hash == SAMPLE_VKH

    def test_capabilities_is_list(self):
        datum = self.make_datum()
        caps = list(datum.capabilities)
        assert caps == [b"testing", b"research"]

    def test_cbor_is_deterministic(self):
        d1 = self.make_datum()
        d2 = self.make_datum()
        assert d1.to_cbor() == d2.to_cbor()


class TestMintRedeemers:
    def test_register_constr_id(self):
        seed = OutputReference(transaction_id=SAMPLE_TX_HASH, output_index=0)
        redeemer = RegisterRedeemer(seed=seed)
        assert redeemer.CONSTR_ID == 0

    def test_register_cbor_roundtrip(self):
        seed = OutputReference(transaction_id=SAMPLE_TX_HASH, output_index=0)
        redeemer = RegisterRedeemer(seed=seed)
        cbor = redeemer.to_cbor()
        restored = RegisterRedeemer.from_cbor(cbor)
        assert restored.seed.transaction_id == SAMPLE_TX_HASH
        assert restored.seed.output_index == 0

    def test_burn_constr_id(self):
        assert BurnRedeemer.CONSTR_ID == 1

    def test_burn_cbor_roundtrip(self):
        redeemer = BurnRedeemer()
        cbor = redeemer.to_cbor()
        restored = BurnRedeemer.from_cbor(cbor)
        assert isinstance(restored, BurnRedeemer)


class TestSpendRedeemers:
    def test_update_constr_id(self):
        assert UpdateRedeemer.CONSTR_ID == 0

    def test_deregister_constr_id(self):
        assert DeregisterRedeemer.CONSTR_ID == 1

    def test_update_cbor_roundtrip(self):
        redeemer = UpdateRedeemer()
        cbor = redeemer.to_cbor()
        restored = UpdateRedeemer.from_cbor(cbor)
        assert isinstance(restored, UpdateRedeemer)

    def test_deregister_cbor_roundtrip(self):
        redeemer = DeregisterRedeemer()
        cbor = redeemer.to_cbor()
        restored = DeregisterRedeemer.from_cbor(cbor)
        assert isinstance(restored, DeregisterRedeemer)
