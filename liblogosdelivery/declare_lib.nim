import ffi
import waku/factory/waku

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
