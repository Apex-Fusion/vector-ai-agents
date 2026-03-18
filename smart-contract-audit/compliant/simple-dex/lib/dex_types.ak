pub type AssetClass {
  policy_id: ByteArray,
  asset_name: ByteArray,
}

pub type SwapDatum {
  maker: ByteArray,
  offered_asset: AssetClass,
  desired_asset: AssetClass,
  rate_numerator: Int,
  rate_denominator: Int,
}

pub type SwapRedeemer {
  Take { maker_output_index: Int }
  Cancel
}
