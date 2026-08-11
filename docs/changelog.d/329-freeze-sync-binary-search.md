### Fixed

- Site-freeze page sync now locates frozen nodes by binary search over the
  id-sorted node list instead of a linear scan per page, keeping large-corpus
  freezes near-linear with byte-identical graph output
  ([IR schema contract](/docs/contracts/ir-schema.md)).
