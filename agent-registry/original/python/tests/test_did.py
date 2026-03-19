"""Tests for DID utilities."""

from vector_agent.did import make_did, parse_did, is_valid_did

SAMPLE_POLICY_ID = "ab" * 28  # 56 hex chars
SAMPLE_NFT_NAME = "cd" * 32  # 64 hex chars


def test_make_did():
    did = make_did(SAMPLE_POLICY_ID, SAMPLE_NFT_NAME)
    assert did == f"did:vector:agent:{SAMPLE_POLICY_ID}:{SAMPLE_NFT_NAME}"


def test_parse_did():
    did = f"did:vector:agent:{SAMPLE_POLICY_ID}:{SAMPLE_NFT_NAME}"
    policy_id, nft_name = parse_did(did)
    assert policy_id == SAMPLE_POLICY_ID
    assert nft_name == SAMPLE_NFT_NAME


def test_roundtrip():
    did = make_did(SAMPLE_POLICY_ID, SAMPLE_NFT_NAME)
    policy_id, nft_name = parse_did(did)
    assert policy_id == SAMPLE_POLICY_ID
    assert nft_name == SAMPLE_NFT_NAME


def test_is_valid_did():
    assert is_valid_did(f"did:vector:agent:{SAMPLE_POLICY_ID}:{SAMPLE_NFT_NAME}")
    assert not is_valid_did("did:vector:agent:short:short")
    assert not is_valid_did("not-a-did")
    assert not is_valid_did(f"did:other:agent:{SAMPLE_POLICY_ID}:{SAMPLE_NFT_NAME}")


def test_make_did_rejects_bad_policy_id():
    try:
        make_did("tooshort", SAMPLE_NFT_NAME)
        assert False, "Should have raised ValueError"
    except ValueError:
        pass


def test_make_did_rejects_bad_nft_name():
    try:
        make_did(SAMPLE_POLICY_ID, "tooshort")
        assert False, "Should have raised ValueError"
    except ValueError:
        pass


def test_parse_did_rejects_bad_format():
    try:
        parse_did("did:vector:wrong:format")
        assert False, "Should have raised ValueError"
    except ValueError:
        pass
