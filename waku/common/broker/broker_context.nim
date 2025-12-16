import std/[strutils, sysrand]

type BrokerContext* = distinct uint32

func `==`*(a, b: BrokerContext): bool {.borrow.}

func `$`*(bc: BrokerContext): string =
  toHex(uint32(bc), 8)

const DefaultBrokerContext* = BrokerContext(0xCAFFE14E'u32)

proc NewBrokerContext*(): BrokerContext =
  ## Generates a random non-default broker context (as a raw uint32).
  ##
  ## The default broker context is reserved for the provider at index 0.
  ## This helper never returns that value.
  for _ in 0 ..< 16:
    let b = urandom(4)
    if b.len != 4:
      continue
    let key =
      (uint32(b[0]) shl 24) or (uint32(b[1]) shl 16) or (uint32(b[2]) shl 8) or
      uint32(b[3])
    if key != uint32(DefaultBrokerContext):
      return BrokerContext(key)
  BrokerContext(1'u32)
