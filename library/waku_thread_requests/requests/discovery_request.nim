import std/json
import chronos, chronicles, results, strutils, libp2p/multiaddress, ffi
import
  ../../../waku/factory/waku,
  ../../../waku/discovery/waku_dnsdisc,
  ../../../waku/discovery/waku_discv5,
  ../../../waku/waku_core/peers,
  ../../../waku/node/waku_node
  ../../../waku/node/kernel_api,

type DiscoveryMsgType* = enum
  GET_BOOTSTRAP_NODES
  UPDATE_DISCV5_BOOTSTRAP_NODES
  START_DISCV5
  STOP_DISCV5
  PEER_EXCHANGE

type DiscoveryRequest* = object
  operation: DiscoveryMsgType

  ## used in GET_BOOTSTRAP_NODES
  enrTreeUrl: cstring
  nameDnsServer: cstring
  timeoutMs: cint

  ## used in UPDATE_DISCV5_BOOTSTRAP_NODES
  nodes: cstring

  ## used in PEER_EXCHANGE
  numPeers: uint64

proc createShared(
    T: type DiscoveryRequest,
    op: DiscoveryMsgType,
    enrTreeUrl: cstring,
    nameDnsServer: cstring,
    timeoutMs: cint,
    nodes: cstring,
    numPeers: uint64,
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].enrTreeUrl = enrTreeUrl.alloc()
  ret[].nameDnsServer = nameDnsServer.alloc()
  ret[].timeoutMs = timeoutMs
  ret[].nodes = nodes.alloc()
  ret[].numPeers = numPeers
  return ret

proc createRetrieveBootstrapNodesRequest*(
    T: type DiscoveryRequest,
    op: DiscoveryMsgType,
    enrTreeUrl: cstring,
    nameDnsServer: cstring,
    timeoutMs: cint,
): ptr type T =
  return T.createShared(op, enrTreeUrl, nameDnsServer, timeoutMs, "", 0)

proc createUpdateBootstrapNodesRequest*(
    T: type DiscoveryRequest, op: DiscoveryMsgType, nodes: cstring
): ptr type T =
  return T.createShared(op, "", "", 0, nodes, 0)

proc createDiscV5StartRequest*(T: type DiscoveryRequest): ptr type T =
  return T.createShared(START_DISCV5, "", "", 0, "", 0)

proc createDiscV5StopRequest*(T: type DiscoveryRequest): ptr type T =
  return T.createShared(STOP_DISCV5, "", "", 0, "", 0)

proc createPeerExchangeRequest*(
    T: type DiscoveryRequest, numPeers: uint64
): ptr type T =
  return T.createShared(PEER_EXCHANGE, "", "", 0, "", numPeers)

proc destroyShared(self: ptr DiscoveryRequest) =
  deallocShared(self[].enrTreeUrl)
  deallocShared(self[].nameDnsServer)
  deallocShared(self[].nodes)
  deallocShared(self)

proc retrieveBootstrapNodes(
    enrTreeUrl: string, ipDnsServer: string
): Future[Result[seq[string], string]] {.async.} =
  let dnsNameServers = @[parseIpAddress(ipDnsServer)]
  let discoveredPeers: seq[RemotePeerInfo] = (
    await retrieveDynamicBootstrapNodes(enrTreeUrl, dnsNameServers)
  ).valueOr:
    return err("failed discovering peers from DNS: " & $error)

  var multiAddresses = newSeq[string]()

  for discPeer in discoveredPeers:
    for address in discPeer.addrs:
      multiAddresses.add($address & "/p2p/" & $discPeer)

  return ok(multiAddresses)

proc updateDiscv5BootstrapNodes(nodes: string, waku: ptr Waku): Result[void, string] =
  waku.wakuDiscv5.updateBootstrapRecords(nodes).isOkOr:
    return err("error in updateDiscv5BootstrapNodes: " & $error)
  return ok()

proc performPeerExchangeRequestTo(
    numPeers: uint64, waku: ptr Waku
): Future[Result[int, string]] {.async.} =
  let numPeersRecv = (await waku.node.fetchPeerExchangePeers(numPeers)).valueOr:
    return err($error)
  return ok(numPeersRecv)

proc process*(
    self: ptr DiscoveryRequest, waku: ptr Waku
): Future[Result[string, string]] {.async.} =
  defer:
    destroyShared(self)

  case self.operation
  of START_DISCV5:
    let res = await waku.wakuDiscv5.start()
    res.isOkOr:
      error "START_DISCV5 failed", error = error
      return err($error)

    return ok("discv5 started correctly")
  of STOP_DISCV5:
    await waku.wakuDiscv5.stop()

    return ok("discv5 stopped correctly")
  of GET_BOOTSTRAP_NODES:
    let nodes = (
      await retrieveBootstrapNodes($self[].enrTreeUrl, $self[].nameDnsServer)
    ).valueOr:
      error "GET_BOOTSTRAP_NODES failed", error = error
      return err($error)

    ## returns a comma-separated string of bootstrap nodes' multiaddresses
    return ok(nodes.join(","))
  of UPDATE_DISCV5_BOOTSTRAP_NODES:
    updateDiscv5BootstrapNodes($self[].nodes, waku).isOkOr:
      error "UPDATE_DISCV5_BOOTSTRAP_NODES failed", error = error
      return err($error)

    return ok("discovery request processed correctly")
  of PEER_EXCHANGE:
    let numValidPeers = (await performPeerExchangeRequestTo(self[].numPeers, waku)).valueOr:
      error "PEER_EXCHANGE failed", error = error
      return err($error)
    return ok($numValidPeers)

  error "discovery request not handled"
  return err("discovery request not handled")
