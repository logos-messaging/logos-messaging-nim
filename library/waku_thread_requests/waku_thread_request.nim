## This file contains the base message request type that will be handled.
## The requests are created by the main thread and processed by
## the Waku Thread.

import std/json, results
import chronos, chronos/threadsync, ffi
import
  ../../waku/factory/waku,
  ./requests/node_lifecycle_request,
  ./requests/peer_manager_request,
  ./requests/protocols/relay_request,
  ./requests/protocols/store_request,
  ./requests/protocols/lightpush_request,
  ./requests/protocols/filter_request,
  ./requests/debug_node_request,
  ./requests/discovery_request,
  ./requests/ping_request

type RequestType* {.pure.} = enum
  LIFECYCLE
  PEER_MANAGER
  PING
  RELAY
  STORE
  DEBUG
  DISCOVERY
  LIGHTPUSH
  FILTER

type WakuThreadRequest* = object
  reqType: RequestType
  reqContent: pointer
  callback: FFICallBack
  userData: pointer

proc createShared*(
    T: type WakuThreadRequest,
    reqType: RequestType,
    reqContent: pointer,
    callback: FFICallBack,
    userData: pointer,
): ptr type T =
  var ret = createShared(T)
  ret[].reqType = reqType
  ret[].reqContent = reqContent
  ret[].callback = callback
  ret[].userData = userData
  return ret

proc handleRes[T: string | void](
    res: Result[T, string], request: ptr WakuThreadRequest
) =
  ## Handles the Result responses, which can either be Result[string, string] or
  ## Result[void, string].

  defer:
    deallocShared(request)

  if res.isErr():
    foreignThreadGc:
      let msg = "libwaku error: handleRes fireSyncRes error: " & $res.error
      request[].callback(
        RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), request[].userData
      )
    return

  foreignThreadGc:
    var msg: cstring = ""
    when T is string:
      msg = res.get().cstring()
    request[].callback(
      RET_OK, unsafeAddr msg[0], cast[csize_t](len(msg)), request[].userData
    )
  return

proc process*(
    T: type WakuThreadRequest, request: ptr WakuThreadRequest, waku: ptr Waku
) {.async.} =
  let retFut =
    case request[].reqId
    of LIFECYCLE:
      cast[ptr NodeLifecycleRequest](request[].reqContent).process(waku)
    of PEER_MANAGER:
      cast[ptr PeerManagementRequest](request[].reqContent).process(waku[])
    of PING:
      cast[ptr PingRequest](request[].reqContent).process(waku)
    of RELAY:
      cast[ptr RelayRequest](request[].reqContent).process(waku)
    of STORE:
      cast[ptr StoreRequest](request[].reqContent).process(waku)
    of DEBUG:
      cast[ptr DebugNodeRequest](request[].reqContent).process(waku[])
    of DISCOVERY:
      cast[ptr DiscoveryRequest](request[].reqContent).process(waku)
    of LIGHTPUSH:
      cast[ptr LightpushRequest](request[].reqContent).process(waku)
    of FILTER:
      cast[ptr FilterRequest](request[].reqContent).process(waku)

  handleRes(await retFut, request)

proc `$`*(self: WakuThreadRequest): string =
  return $self.reqType
