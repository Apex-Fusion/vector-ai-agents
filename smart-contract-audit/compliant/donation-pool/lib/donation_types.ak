pub type DonationDatum {
  admin: ByteArray,
}

pub type Distribution {
  recipient: ByteArray,
  amount: Int,
}

pub type DonationRedeemer {
  Distribute { distributions: List<Distribution> }
}
