# Agent Notes — Agent Registry

## Deployment

### Prerequisites
- Aiken v1.1.21 or later
- Aiken stdlib v3.0.0
- Target: Plutus V3

### Steps
1. Build the contract with `aiken build` — this produces the Plutus V3 blueprint
2. Extract the compiled validator from the blueprint JSON
3. Deploy the multi-validator to Vector/Cardano as a reference script (recommended) or embed in transactions
4. The script hash becomes both the minting policy ID and the payment credential of the registry address
5. No parameterization needed — the contract is self-referencing via its own script hash

### Verification
- Run `aiken check` to execute all tests before deployment
- The contract hash should be deterministic from the source — verify it matches across environments

## Parameters

### On-Chain Constants (Hardcoded)

| Parameter | Value | Description |
|-----------|-------|-------------|
| `min_deposit_lovelace` | `10_000_000` | Minimum 10 AP3X (in DFM) deposit per agent |
| `max_name_length` | `256` | Maximum agent name in bytes |
| `max_description_length` | `1024` | Maximum description in bytes |
| `max_capability_length` | `128` | Maximum bytes per capability tag |
| `max_capabilities_count` | `32` | Maximum capability tags per agent |
| `max_framework_length` | `128` | Maximum framework identifier in bytes |
| `max_endpoint_length` | `512` | Maximum endpoint URL in bytes |

### Tuning Notes
- These constants are compiled into the script. Changing any of them produces a **different script hash** (new policy ID, new registry address)
- The minimum deposit should be high enough to discourage spam but low enough to encourage adoption
- Field size limits are generous for V1 — tighten if indexer performance is a concern

## Integration

### Off-Chain SDK Requirements
- **Registration:** Must select a seed UTxO from the user's wallet and derive the NFT asset name using `blake2b_256(cbor.serialise(seed_output_reference))`
- **Update:** Must look up the current agent UTxO at the script address by NFT name, then construct a continuing output with the same NFT and ≥ input value
- **Deregister:** Must include both the spend input (Deregister redeemer) and the mint (Burn redeemer) in the same transaction. Must also produce an output to the owner with ≥ minimum deposit

### Indexer Integration
- Agents are discoverable by querying UTxOs at the script address
- Each UTxO contains an inline `AgentDatum` — no datum lookup needed
- The NFT asset name is the stable agent identifier; use it to construct the DID: `did:vector:agent:{policy_id}:{asset_name}`
- Watch for `Register` and `Deregister` events by monitoring mints/burns under the policy ID

### Cross-Contract Interaction
- Other contracts can verify agent identity by checking for the NFT under the registry's policy ID
- The soulbound property means the NFT is always at the script address — never in a user wallet
- To check if an agent is registered: look for a UTxO at the script address containing the expected NFT name

## Modifications

### Changing the Minimum Deposit
- Edit `min_deposit_lovelace` in `validation.ak`
- This changes the script hash — you'll need to re-deploy and migrate existing registrations

### Adding New Datum Fields
- Add fields to `AgentDatum` in `types.ak`
- Add size limits in `validation.ak` if applicable
- Update `validate_datum_size` to check new fields
- This is a breaking change — existing datums won't deserialize correctly against the new type

### Supporting Batch Operations
- The `script_input_count == 1` check in `validate_update` prevents batch operations (see NF-03)
- To re-enable: replace with 1:1 input-output binding using NFT name matching
- This is more complex but allows multiple agent updates in one transaction

### Adding Governance / Admin Key
- The contract currently has no admin override
- To add: introduce a parameterized governance key and add a governance bypass path
- Consider: this changes the trust model significantly

## Gotchas

### Soulbound NFT — Don't Look for It in Wallets
The identity NFT is **never** in a user's wallet. It's always at the script address. SDKs and wallets that look for NFTs in personal addresses will not find agent identities. Query the script address instead.

### Script Hash = Policy ID = Address
The multi-validator's hash serves triple duty. If you change the script at all (even whitespace in comments, depending on compiler behavior), you get a different hash, which means a different policy ID and a different registry address. Pin your source exactly.

### Value Preservation on Update
The compliant contract requires `output_lovelace >= input_lovelace`. If an agent UTxO receives unsolicited donations (tokens sent to the script address), those extra tokens are effectively locked — the update must preserve at least the input's lovelace value. This is by design (prevents value draining) but can surprise users.

### One Operation Per Transaction
Due to the AR-01 fix, you cannot update/deregister multiple agents in the same transaction. Each agent operation requires its own transaction. This increases fees for bulk operations but eliminates double-satisfaction attacks.

### Empty Fields Are Valid On-Chain
The contract enforces maximum field sizes but not minimums. An agent with an empty name and no capabilities is valid on-chain. Enforce minimum requirements in your SDK/off-chain layer.

### Owner Transfer Is Unrestricted
The compliant contract allows changing the `owner` field on Update (as long as the current owner signs). There is no on-chain confirmation from the new owner. The new owner gains full control immediately. Consider adding a two-step transfer (propose + accept) in a future version.

### Deposit Return on Deregister Is Approximate
The deposit return check (AR-10) verifies that *some* output to the owner has `≥ min_deposit_lovelace`, but this can be satisfied by unrelated outputs in the transaction (e.g., change from other inputs). It's a safety net, not a guarantee. Use the SDK to construct clean deregistration transactions.

### `registered_at` Is Immutable but Self-Reported
The `registered_at` timestamp is preserved on Update (AR-04 fix) but is set by the registrant during initial registration. There's no on-chain clock check — the value is whatever the transaction builder puts in. Use slot-to-time conversion for verification if needed.
