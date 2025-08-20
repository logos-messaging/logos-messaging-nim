import std/[sequtils, strutils, tables]
import chronicles, chronos, results, options, json, ffi
import
  ../../../waku/factory/waku,
  ../../../waku/node/waku_node,
  ../../../waku/node/peer_manager

type PeerManagementMsgType* {.pure.} = enum
  CONNECT_TO
  GET_ALL_PEER_IDS
  GET_CONNECTED_PEERS_INFO
  GET_PEER_IDS_BY_PROTOCOL
  DISCONNECT_PEER_BY_ID
  DISCONNECT_ALL_PEERS
  DIAL_PEER
  DIAL_PEER_BY_ID
  GET_CONNECTED_PEERS

type PeerManagementRequest* = object
  operation: PeerManagementMsgType
  peerMultiAddr: cstring
  dialTimeout: Duration
  protocol: cstring
  peerId: cstring

type PeerInfo = object
  protocols: seq[string]
  addresses: seq[string]

proc createShared*(
    T: type PeerManagementRequest,
    op: PeerManagementMsgType,
    peerMultiAddr = "",
    dialTimeout = chronos.milliseconds(0), ## arbitrary Duration as not all ops needs dialTimeout
    peerId = "",
    protocol = "",
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].peerMultiAddr = peerMultiAddr.alloc()
  ret[].peerId = peerId.alloc()
  ret[].protocol = protocol.alloc()
  ret[].dialTimeout = dialTimeout
  return ret

proc destroyShared(self: ptr PeerManagementRequest) =
  if not isNil(self[].peerMultiAddr):
    deallocShared(self[].peerMultiAddr)

  if not isNil(self[].peerId):
    deallocShared(self[].peerId)

  if not isNil(self[].protocol):
    deallocShared(self[].protocol)

  deallocShared(self)

proc process*(
    self: ptr PeerManagementRequest, waku: ptr Waku
): Future[Result[string, string]] {.async.} =
  defer:
    destroyShared(self)

  case self.operation
  of CONNECT_TO:
    let peers = ($self[].peerMultiAddr).split(",").mapIt(strip(it))
    await waku[].node.connectToNodes(peers, source = "static")
    return ok("")
  of GET_ALL_PEER_IDS:
    ## returns a comma-separated string of peerIDs
    let peerIDs =
      waku[].node.peerManager.switch.peerStore.peers().mapIt($it.peerId).join(",")
    return ok(peerIDs)
  of GET_CONNECTED_PEERS_INFO:
    ## returns a JSON string mapping peerIDs to objects with protocols and addresses

    var peersMap = initTable[string, PeerInfo]()
    let peers = waku[].node.peerManager.switch.peerStore.peers().filterIt(
        it.connectedness == Connected
      )

    # Build a map of peer IDs to peer info objects
    for peer in peers:
      let peerIdStr = $peer.peerId
      peersMap[peerIdStr] =
        PeerInfo(protocols: peer.protocols, addresses: peer.addrs.mapIt($it))

    # Convert the map to JSON string
    let jsonObj = %*peersMap
    let jsonStr = $jsonObj
    return ok(jsonStr)
  of GET_PEER_IDS_BY_PROTOCOL:
    ## returns a comma-separated string of peerIDs that mount the given protocol
    let connectedPeers = waku[].node.peerManager.switch.peerStore
      .peers($self[].protocol)
      .filterIt(it.connectedness == Connected)
      .mapIt($it.peerId)
      .join(",")
    return ok(connectedPeers)
  of DISCONNECT_PEER_BY_ID:
    let peerId = PeerId.init($self[].peerId).valueOr:
      error "DISCONNECT_PEER_BY_ID failed", error = $error
      return err($error)
    await waku[].node.peerManager.disconnectNode(peerId)
    return ok("")
  of DISCONNECT_ALL_PEERS:
    await waku[].node.peerManager.disconnectAllPeers()
    return ok("")
  of DIAL_PEER:
    let remotePeerInfo = parsePeerInfo($self[].peerMultiAddr).valueOr:
      error "DIAL_PEER failed", error = $error
      return err($error)
    let conn = await waku[].node.peerManager.dialPeer(remotePeerInfo, $self[].protocol)
    if conn.isNone():
      let msg = "failed dialing peer"
      error "DIAL_PEER failed", error = msg, peerId = $remotePeerInfo.peerId
      return err(msg)
  of DIAL_PEER_BY_ID:
    let peerId = PeerId.init($self[].peerId).valueOr:
      error "DIAL_PEER_BY_ID failed", error = $error
      return err($error)
    let conn = await waku[].node.peerManager.dialPeer(peerId, $self[].protocol)
    if conn.isNone():
      let msg = "failed dialing peer"
      error "DIAL_PEER_BY_ID failed", error = msg, peerId = $peerId
      return err(msg)
  of GET_CONNECTED_PEERS:
    ## returns a comma-separated string of peerIDs
    let
      (inPeerIds, outPeerIds) = waku[].node.peerManager.connectedPeers()
      connectedPeerids = concat(inPeerIds, outPeerIds)
    return ok(connectedPeerids.mapIt($it).join(","))

  return ok("")
