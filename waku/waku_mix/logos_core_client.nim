{.push raises: [].}

## Logos-core RLN client: push-based root/proof delivery from C++ plugin.
##
## The C++ delivery module plugin pushes roots via logosdelivery_push_valid_roots,
## and this module provides callback factories that read from the cache.
## Push procs (pushValidRoots, pushMerkleProof) are called from the FFI layer.
## Callback factories are used by protocol.nim when wiring up spam protection.

import std/[json, strutils, locks]
import chronos
import results

const HashByteSize = 32

type
  MerkleNode* = array[HashByteSize, byte]
  RlnResult*[T] = Result[T, string]

var
  rootsLock: Lock
  cachedRootsJson: string
  cachedProofJson: string

rootsLock.initLock()

proc hexToBytes32(hex: string): Result[array[32, byte], string] =
  var h = hex
  if h.startsWith("0x") or h.startsWith("0X"):
    h = h[2 .. ^1]
  if h.len != 64:
    return err("Expected 64 hex chars, got " & $h.len)
  var output: array[32, byte]
  for i in 0 ..< 32:
    try:
      output[i] = byte(parseHexInt(h[i * 2 .. i * 2 + 1]))
    except ValueError:
      return err("Invalid hex at position " & $i)
  ok(output)

proc pushValidRoots*(rootsJson: string) =
  rootsLock.acquire()
  cachedRootsJson = rootsJson
  rootsLock.release()

proc pushMerkleProof*(proofJson: string) =
  rootsLock.acquire()
  cachedProofJson = proofJson
  rootsLock.release()

proc getCachedRootsJson*(): string =
  rootsLock.acquire()
  result = cachedRootsJson
  rootsLock.release()

proc getCachedProofJson*(): string =
  rootsLock.acquire()
  result = cachedProofJson
  rootsLock.release()

proc parseRootsJson*(snapshot: string): RlnResult[seq[MerkleNode]] =
  if snapshot.len == 0:
    return err("No roots pushed yet")
  try:
    let parsed = parseJson(snapshot)
    var roots: seq[MerkleNode]
    for elem in parsed:
      let root = hexToBytes32(elem.getStr()).valueOr:
        return err("Invalid root hex: " & error)
      roots.add(MerkleNode(root))
    return ok(roots)
  except CatchableError as e:
    return err("Failed to parse pushed roots: " & e.msg)

{.pop.}
