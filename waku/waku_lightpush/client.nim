{.push raises: [].}

import std/options, results, chronicles, chronos, metrics, bearssl/rand, stew/byteutils
import libp2p/peerid, libp2p/stream/connection
import
  ../waku_core/peers,
  ../node/peer_manager,
  ../node/delivery_monitor/publish_observer,
  ../utils/requests,
  ../waku_core,
  ./common,
  ./protocol_metrics,
  ./rpc,
  ./rpc_codec

logScope:
  topics = "waku lightpush client"

type WakuLightPushClient* = ref object
  rng*: ref rand.HmacDrbgContext
  peerManager*: PeerManager
  publishObservers: seq[PublishObserver]

proc new*(
    T: type WakuLightPushClient, peerManager: PeerManager, rng: ref rand.HmacDrbgContext
): T =
  WakuLightPushClient(peerManager: peerManager, rng: rng)

proc addPublishObserver*(wl: WakuLightPushClient, obs: PublishObserver) =
  wl.publishObservers.add(obs)

proc ensureTimestampSet(message: var WakuMessage) =
  if message.timestamp == 0:
    message.timestamp = getNowInNanosecondTime()

## Short log string for peer identifiers (overloads for convenience)
func shortPeerId(peer: PeerId): string =
  shortLog(peer)

func shortPeerId(peer: RemotePeerInfo): string =
  shortLog(peer.peerId)

proc sendPushRequestToConn(
    wl: WakuLightPushClient, request: LightPushRequest, conn: Connection
): Future[WakuLightPushResult] {.async.} =
  try:
    await conn.writeLp(request.encode().buffer)
  except LPStreamError:
    error "Failed to write request to peer", error = getCurrentExceptionMsg()
    return lightpushResultInternalError(
      "Failed to write request to peer: " & getCurrentExceptionMsg()
    )

  var buffer: seq[byte]
  try:
    buffer = await conn.readLp(DefaultMaxRpcSize.int)
  except LPStreamRemoteClosedError:
    error "Failed to read response from peer", error = getCurrentExceptionMsg()
    return lightpushResultInternalError(
      "Failed to read response from peer: " & getCurrentExceptionMsg()
    )
  let response = LightpushResponse.decode(buffer).valueOr:
    error "failed to decode response", error = $error
    waku_lightpush_v3_errors.inc(labelValues = [decodeRpcFailure])
    return lightpushResultInternalError(decodeRpcFailure)

  let requestIdMismatch = response.requestId != request.requestId
  let tooManyRequests = response.statusCode == LightPushErrorCode.TOO_MANY_REQUESTS
  if requestIdMismatch and (not tooManyRequests):
    # response with TOO_MANY_REQUESTS error code has no requestId by design
    error "response failure, requestId mismatch",
      requestId = request.requestId, responseRequestId = response.requestId
    return lightpushResultInternalError("response failure, requestId mismatch")

  return toPushResult(response)

proc publish*(
    wl: WakuLightPushClient,
    pubSubTopic: Option[PubsubTopic] = none(PubsubTopic),
    wakuMessage: WakuMessage,
    dest: Connection | PeerId | RemotePeerInfo,
): Future[WakuLightPushResult] {.async, gcsafe.} =
  let conn =
    when dest is Connection:
      dest
    else:
      (await wl.peerManager.dialPeer(dest, WakuLightPushCodec)).valueOr:
        waku_lightpush_v3_errors.inc(labelValues = [dialFailure])
        return lighpushErrorResult(
          LightPushErrorCode.NO_PEERS_TO_RELAY,
          "Peer is not accessible: " & dialFailure & " - " & $dest,
        )

  defer:
    await conn.closeWithEOF()

  var message = wakuMessage
  ensureTimestampSet(message)

  let msgHash = computeMessageHash(pubSubTopic.get(""), message).to0xHex()
  info "publish",
    myPeerId = wl.peerManager.switch.peerInfo.peerId,
    peerId = shortPeerId(conn.peerId),
    msgHash = msgHash,
    sentTime = getNowInNanosecondTime()

  let request = LightpushRequest(
    requestId: generateRequestId(wl.rng), pubsubTopic: pubSubTopic, message: message
  )
  let relayPeerCount = ?await wl.sendPushRequestToConn(request, conn)

  for obs in wl.publishObservers:
    obs.onMessagePublished(pubSubTopic.get(""), message)

  return lightpushSuccessResult(relayPeerCount)

proc publishToAny*(
    wl: WakuLightPushClient, pubsubTopic: PubsubTopic, wakuMessage: WakuMessage
): Future[WakuLightPushResult] {.async, gcsafe.} =
  # Like publish, but selects a peer automatically from the peer manager
  let peer = wl.peerManager.selectPeer(WakuLightPushCodec).valueOr:
    # TODO: check if it is matches the situation - shall we distinguish client side missing peers from server side?
    return lighpushErrorResult(
      LightPushErrorCode.NO_PEERS_TO_RELAY, "no suitable remote peers"
    )
  return await wl.publish(some(pubsubTopic), wakuMessage, peer)
