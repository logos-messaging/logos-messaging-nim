import std/[net, sequtils, strutils]
import chronicles, chronos, stew/byteutils, results, ffi
import
  waku/waku_core/message/message,
  waku/factory/[validator_signed, waku],
  tools/confutils/cli_args,
  waku/waku_node,
  waku/waku_core/message,
  waku/waku_core/time, # Timestamp
  waku/waku_core/topics/pubsub_topic,
  waku/waku_core/topics,
  waku/waku_relay/protocol,
  waku/node/peer_manager
  
import

type RelayMsgType* = enum
  SUBSCRIBE
  UNSUBSCRIBE
  PUBLISH
  NUM_CONNECTED_PEERS
  LIST_CONNECTED_PEERS
    ## to return the list of all connected peers to an specific pubsub topic
  NUM_MESH_PEERS
  LIST_MESH_PEERS
    ## to return the list of only the peers that conform the mesh for a particular pubsub topic
  ADD_PROTECTED_SHARD ## Protects a shard with a public key

type ThreadSafeWakuMessage* = object
  payload: SharedSeq[byte]
  contentTopic: cstring
  meta: SharedSeq[byte]
  version: uint32
  timestamp: Timestamp
  ephemeral: bool
  when defined(rln):
    proof: SharedSeq[byte]

type RelayRequest* = object
  operation: RelayMsgType
  pubsubTopic: cstring
  relayEventCallback: WakuRelayHandler # not used in 'PUBLISH' requests
  message: ThreadSafeWakuMessage # only used in 'PUBLISH' requests
  clusterId: cint # only used in 'ADD_PROTECTED_SHARD' requests
  shardId: cint # only used in 'ADD_PROTECTED_SHARD' requests
  publicKey: cstring # only used in 'ADD_PROTECTED_SHARD' requests

proc createShared*(
    T: type RelayRequest,
    op: RelayMsgType,
    pubsubTopic: cstring = nil,
    relayEventCallback: WakuRelayHandler = nil,
    m = WakuMessage(),
    clusterId: cint = 0,
    shardId: cint = 0,
    publicKey: cstring = nil,
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].pubsubTopic = pubsubTopic.alloc()
  ret[].clusterId = clusterId
  ret[].shardId = shardId
  ret[].publicKey = publicKey.alloc()
  ret[].relayEventCallback = relayEventCallback
  ret[].message = ThreadSafeWakuMessage(
    payload: allocSharedSeq(m.payload),
    contentTopic: m.contentTopic.alloc(),
    meta: allocSharedSeq(m.meta),
    version: m.version,
    timestamp: m.timestamp,
    ephemeral: m.ephemeral,
  )
  when defined(rln):
    ret[].message.proof = allocSharedSeq(m.proof)

  return ret

proc destroyShared(self: ptr RelayRequest) =
  deallocSharedSeq(self[].message.payload)
  deallocShared(self[].message.contentTopic)
  deallocSharedSeq(self[].message.meta)
  when defined(rln):
    deallocSharedSeq(self[].message.proof)
  deallocShared(self[].pubsubTopic)
  deallocShared(self[].publicKey)
  deallocShared(self)

proc toWakuMessage(m: ThreadSafeWakuMessage): WakuMessage =
  var wakuMessage = WakuMessage()

  wakuMessage.payload = m.payload.toSeq()
  wakuMessage.contentTopic = $m.contentTopic
  wakuMessage.meta = m.meta.toSeq()
  wakuMessage.version = m.version
  wakuMessage.timestamp = m.timestamp
  wakuMessage.ephemeral = m.ephemeral

  when defined(rln):
    wakuMessage.proof = m.proof

  return wakuMessage

proc process*(
    self: ptr RelayRequest, waku: ptr Waku
): Future[Result[string, string]] {.async.} =
  defer:
    destroyShared(self)

  if waku.node.wakuRelay.isNil():
    return err("Operation not supported without Waku Relay enabled.")

  case self.operation
  of SUBSCRIBE:
    waku.node.subscribe(
      (kind: SubscriptionKind.PubsubSub, topic: $self.pubsubTopic),
      handler = self.relayEventCallback,
    ).isOkOr:
      error "SUBSCRIBE failed", error
      return err($error)
  of UNSUBSCRIBE:
    waku.node.unsubscribe((kind: SubscriptionKind.PubsubSub, topic: $self.pubsubTopic)).isOkOr:
      error "UNSUBSCRIBE failed", error
      return err($error)
  of PUBLISH:
    let msg = self.message.toWakuMessage()
    let pubsubTopic = $self.pubsubTopic

    (await waku.node.wakuRelay.publish(pubsubTopic, msg)).isOkOr:
      error "PUBLISH failed", error
      return err($error)

    let msgHash = computeMessageHash(pubSubTopic, msg).to0xHex
    return ok(msgHash)
  of NUM_CONNECTED_PEERS:
    let numConnPeers = waku.node.wakuRelay.getNumConnectedPeers($self.pubsubTopic).valueOr:
      error "NUM_CONNECTED_PEERS failed", error
      return err($error)
    return ok($numConnPeers)
  of LIST_CONNECTED_PEERS:
    let connPeers = waku.node.wakuRelay.getConnectedPeers($self.pubsubTopic).valueOr:
      error "LIST_CONNECTED_PEERS failed", error = error
      return err($error)
    ## returns a comma-separated string of peerIDs
    return ok(connPeers.mapIt($it).join(","))
  of NUM_MESH_PEERS:
    let numPeersInMesh = waku.node.wakuRelay.getNumPeersInMesh($self.pubsubTopic).valueOr:
      error "NUM_MESH_PEERS failed", error = error
      return err($error)
    return ok($numPeersInMesh)
  of LIST_MESH_PEERS:
    let meshPeers = waku.node.wakuRelay.getPeersInMesh($self.pubsubTopic).valueOr:
      error "LIST_MESH_PEERS failed", error = error
      return err($error)
    ## returns a comma-separated string of peerIDs
    return ok(meshPeers.mapIt($it).join(","))
  of ADD_PROTECTED_SHARD:
    try:
      let relayShard =
        RelayShard(clusterId: uint16(self.clusterId), shardId: uint16(self.shardId))
      let protectedShard =
        ProtectedShard.parseCmdArg($relayShard & ":" & $self.publicKey)
      waku.node.wakuRelay.addSignedShardsValidator(
        @[protectedShard], uint16(self.clusterId)
      )
    except ValueError:
      return err(getCurrentExceptionMsg())
  return ok("")
