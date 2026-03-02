import ffi
import waku/factory/waku
import waku/waku_mix/logos_core_client

declareLibrary("logosdelivery")

template requireInitializedNode*(
    ctx: ptr FFIContext[Waku], opName: string, onError: untyped
) =
  if isNil(ctx):
    let errMsg {.inject.} = opName & " failed: invalid context"
    onError
  elif isNil(ctx.myLib) or isNil(ctx.myLib[]):
    let errMsg {.inject.} = opName & " failed: node is not initialized"
    onError

proc logosdelivery_set_event_callback(
    ctx: ptr FFIContext[Waku], callback: FFICallBack, userData: pointer
) {.dynlib, exportc, cdecl.} =
  if isNil(ctx):
    echo "error: invalid context in logosdelivery_set_event_callback"
    return

  ctx[].eventCallback = cast[pointer](callback)
  ctx[].eventUserData = userData

proc logosdelivery_push_valid_roots(
    ctx: ptr FFIContext[Waku], rootsJson: cstring, rootsLen: csize_t
): cint {.dynlib, exportc, cdecl.} =
  if rootsJson.isNil or rootsLen == 0:
    return RET_ERR
  pushValidRoots($rootsJson)
  return RET_OK

proc logosdelivery_push_merkle_proof(
    ctx: ptr FFIContext[Waku], proofJson: cstring, proofLen: csize_t
): cint {.dynlib, exportc, cdecl.} =
  if proofJson.isNil or proofLen == 0:
    return RET_ERR
  pushMerkleProof($proofJson)
  return RET_OK
