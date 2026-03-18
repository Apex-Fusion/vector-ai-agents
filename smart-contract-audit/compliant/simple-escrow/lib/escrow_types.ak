pub type EscrowDatum {
  beneficiary: ByteArray,
  sender: ByteArray,
  deadline: Int,
  secret_hash: ByteArray,
}

pub type EscrowRedeemer {
  Claim { secret: ByteArray }
  Reclaim
}
