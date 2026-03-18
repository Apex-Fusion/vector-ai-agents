pub type VestingDatum {
  beneficiary: ByteArray,
  total_vesting_amount: Int,
  cliff_time: Int,
  vesting_end_time: Int,
}

pub type VestingRedeemer {
  Claim { beneficiary_index: Int, continuation_index: Int }
}
