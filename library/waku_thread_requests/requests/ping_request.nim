import std/[json, strutils]
import chronos, results, ffi
import libp2p/[protocols/ping, switch, multiaddress, multicodec]
import ../../../waku/[factory/waku, waku_core/peers, node/waku_node]

type PingRequest* = object
  peerAddr: cstring
  timeout: Duration

proc createShared*(
    T: type PingRequest, peerAddr: cstring, timeout: Duration
): ptr type T =
  var ret = createShared(T)
  ret[].peerAddr = peerAddr.alloc()
  ret[].timeout = timeout
  return ret

proc destroyShared(self: ptr PingRequest) =
  deallocShared(self[].peerAddr)
  deallocShared(self)

proc process*(
    self: ptr PingRequest, waku: ptr Waku
): Future[Result[string, string]] {.async.} =
  defer:
    destroyShared(self)

  let peerInfo = peers.parsePeerInfo(($self[].peerAddr).split(",")).valueOr:
    return err("PingRequest failed to parse peer addr: " & $error)

  proc ping(): Future[Result[Duration, string]] {.async, gcsafe.} =
    try:
      let conn = await waku.node.switch.dial(peerInfo.peerId, peerInfo.addrs, PingCodec)
      defer:
        await conn.close()

      let pingRTT = await waku.node.libp2pPing.ping(conn)
      if pingRTT == 0.nanos:
        return err("could not ping peer: rtt-0")
      return ok(pingRTT)
    except CatchableError:
      return err("could not ping peer: " & getCurrentExceptionMsg())

  let pingFuture = ping()
  let pingRTT: Duration =
    if self[].timeout == chronos.milliseconds(0): # No timeout expected
      ?(await pingFuture)
    else:
      let timedOut = not (await pingFuture.withTimeout(self[].timeout))
      if timedOut:
        return err("ping timed out")
      ?(pingFuture.read())

  ok($(pingRTT.nanos))
