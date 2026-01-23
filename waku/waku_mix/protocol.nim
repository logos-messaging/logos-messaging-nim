{.push raises: [].}

import chronicles, std/[options, tables, sequtils], chronos, results, metrics, strutils

import
  libp2p/crypto/curve25519,
  libp2p/protocols/mix,
  libp2p/protocols/mix/mix_node,
  libp2p/protocols/mix/mix_protocol,
  libp2p/protocols/mix/mix_metrics,
  libp2p/protocols/mix/spam_protection,
  libp2p/[multiaddress, multicodec, peerid],
  eth/common/keys

import
  mix_rln_spam_protection,
  ../node/peer_manager,
  ../waku_core,
  ../waku_relay,
  ../waku_enr,
  ../node/peer_manager/waku_peer_store,
  ../common/nimchronos

logScope:
  topics = "waku mix"

const minMixPoolSize = 4

type
  PublishMessage* = proc(message: WakuMessage): Future[Result[void, string]] {.
    async, gcsafe, raises: []
  .}

  WakuMix* = ref object of MixProtocol
    peerManager*: PeerManager
    clusterId: uint16
    nodePoolLoopHandle: Future[void]
    pubKey*: Curve25519Key
    mixRlnSpamProtection*: MixRlnSpamProtection
    publishMessage*: PublishMessage

  WakuMixResult*[T] = Result[T, string]

  MixNodePubInfo* = object
    multiAddr*: string
    pubKey*: Curve25519Key

proc filterMixNodes(cluster: Option[uint16], peer: RemotePeerInfo): bool =
  # Note that origin based(discv5) filtering is not done intentionally
  # so that more mix nodes can be discovered.
  if peer.mixPubKey.isNone():
    trace "remote peer has no mix Pub Key", peer = $peer
    return false

  if cluster.isSome() and peer.enr.isSome() and
      peer.enr.get().isClusterMismatched(cluster.get()):
    trace "peer has mismatching cluster", peer = $peer
    return false

  return true

proc appendPeerIdToMultiaddr*(multiaddr: MultiAddress, peerId: PeerId): MultiAddress =
  if multiaddr.contains(multiCodec("p2p")).get():
    return multiaddr

  var maddrStr = multiaddr.toString().valueOr:
    error "Failed to convert multiaddress to string.", err = error
    return multiaddr
  maddrStr.add("/p2p/" & $peerId)
  var cleanAddr = MultiAddress.init(maddrStr).valueOr:
    error "Failed to convert string to multiaddress.", err = error
    return multiaddr
  return cleanAddr

func getIPv4Multiaddr*(maddrs: seq[MultiAddress]): Option[MultiAddress] =
  for multiaddr in maddrs:
    trace "checking multiaddr", addr = $multiaddr
    if multiaddr.contains(multiCodec("ip4")).get():
      trace "found ipv4 multiaddr", addr = $multiaddr
      return some(multiaddr)
  trace "no ipv4 multiaddr found"
  return none(MultiAddress)

proc populateMixNodePool*(mix: WakuMix) =
  # populate only peers that i) are reachable ii) share cluster iii) support mix
  let remotePeers = mix.peerManager.switch.peerStore.peers().filterIt(
      filterMixNodes(some(mix.clusterId), it)
    )
  var mixNodes = initTable[PeerId, MixPubInfo]()

  for i in 0 ..< min(remotePeers.len, 100):
    let ipv4addr = getIPv4Multiaddr(remotePeers[i].addrs).valueOr:
      trace "peer has no ipv4 address", peer = $remotePeers[i]
      continue
    let maddrWithPeerId = appendPeerIdToMultiaddr(ipv4addr, remotePeers[i].peerId)
    trace "remote peer info", info = remotePeers[i]

    if remotePeers[i].mixPubKey.isNone():
      trace "peer has no mix Pub Key", remotePeerId = $remotePeers[i]
      continue

    let peerMixPubKey = remotePeers[i].mixPubKey.get()
    var peerPubKey: crypto.PublicKey
    if not remotePeers[i].peerId.extractPublicKey(peerPubKey):
      warn "Failed to extract public key from peerId, skipping node",
        remotePeerId = remotePeers[i].peerId
      continue

    if peerPubKey.scheme != PKScheme.Secp256k1:
      warn "Peer public key is not Secp256k1, skipping node",
        remotePeerId = remotePeers[i].peerId, scheme = peerPubKey.scheme
      continue

    let mixNodePubInfo = MixPubInfo.init(
      remotePeers[i].peerId,
      ipv4addr,
      intoCurve25519Key(peerMixPubKey),
      peerPubKey.skkey,
    )
    trace "adding mix node to pool",
      remotePeerId = remotePeers[i].peerId, multiAddr = $ipv4addr
    mixNodes[remotePeers[i].peerId] = mixNodePubInfo

  # set the mix node pool
  mix.setNodePool(mixNodes)
  mix_pool_size.set(len(mixNodes))
  trace "mix node pool updated", poolSize = mix.getNodePoolSize()

# Once mix protocol starts to use info from PeerStore, then this can be removed.
proc startMixNodePoolMgr*(mix: WakuMix) {.async.} =
  info "starting mix node pool manager"
  # try more aggressively to populate the pool at startup
  var attempts = 50
  # TODO: make initial pool size configurable
  while mix.getNodePoolSize() < 100 and attempts > 0:
    attempts -= 1
    mix.populateMixNodePool()
    await sleepAsync(1.seconds)

  # TODO: make interval configurable
  heartbeat "Updating mix node pool", 5.seconds:
    mix.populateMixNodePool()

proc processBootNodes(
    bootnodes: seq[MixNodePubInfo], peermgr: PeerManager
): Table[PeerId, MixPubInfo] =
  var mixNodes = initTable[PeerId, MixPubInfo]()
  for node in bootnodes:
    let pInfo = parsePeerInfo(node.multiAddr).valueOr:
      error "Failed to get peer id from multiaddress: ",
        error = error, multiAddr = $node.multiAddr
      continue
    let peerId = pInfo.peerId
    var peerPubKey: crypto.PublicKey
    if not peerId.extractPublicKey(peerPubKey):
      warn "Failed to extract public key from peerId, skipping node", peerId = peerId
      continue

    if peerPubKey.scheme != PKScheme.Secp256k1:
      warn "Peer public key is not Secp256k1, skipping node",
        peerId = peerId, scheme = peerPubKey.scheme
      continue

    let multiAddr = MultiAddress.init(node.multiAddr).valueOr:
      error "Failed to parse multiaddress", multiAddr = node.multiAddr, error = error
      continue

    mixNodes[peerId] = MixPubInfo.init(peerId, multiAddr, node.pubKey, peerPubKey.skkey)

    peermgr.addPeer(
      RemotePeerInfo.init(peerId, @[multiAddr], mixPubKey = some(node.pubKey))
    )
  mix_pool_size.set(len(mixNodes))
  info "using mix bootstrap nodes ", bootNodes = mixNodes
  return mixNodes

proc new*(
    T: type WakuMix,
    nodeAddr: string,
    peermgr: PeerManager,
    clusterId: uint16,
    mixPrivKey: Curve25519Key,
    bootnodes: seq[MixNodePubInfo],
    publishMessage: PublishMessage,
): WakuMixResult[T] =
  let mixPubKey = public(mixPrivKey)
  info "mixPubKey", mixPubKey = mixPubKey
  let nodeMultiAddr = MultiAddress.init(nodeAddr).valueOr:
    return err("failed to parse mix node address: " & $nodeAddr & ", error: " & error)
  let localMixNodeInfo = initMixNodeInfo(
    peermgr.switch.peerInfo.peerId, nodeMultiAddr, mixPubKey, mixPrivKey,
    peermgr.switch.peerInfo.publicKey.skkey, peermgr.switch.peerInfo.privateKey.skkey,
  )
  if bootnodes.len < minMixPoolSize:
    warn "publishing with mix won't work until atleast 3 mix nodes in node pool"
  let initTable = processBootNodes(bootnodes, peermgr)

  if len(initTable) < minMixPoolSize:
    warn "publishing with mix won't work until atleast  3 mix nodes in node pool"

  # Initialize spam protection with default config (ephemeral credentials)
  let spamProtectionConfig = defaultConfig()
  let spamProtection = newMixRlnSpamProtection(spamProtectionConfig).valueOr:
    return err("failed to create spam protection: " & error)

  var m = WakuMix(
    peerManager: peermgr,
    clusterId: clusterId,
    pubKey: mixPubKey,
    mixRlnSpamProtection: spamProtection,
    publishMessage: publishMessage,
  )
  procCall MixProtocol(m).init(
    localMixNodeInfo,
    initTable,
    peermgr.switch,
    spamProtection = Opt.some(SpamProtection(spamProtection)),
  )
  return ok(m)

proc setupSpamProtectionCallbacks(mix: WakuMix) =
  ## Set up the publish callback for spam protection coordination.
  ## This enables the plugin to broadcast membership updates and proof metadata
  ## via Waku relay.
  if mix.publishMessage.isNil():
    warn "PublishMessage callback not available, spam protection coordination disabled"
    return

  let publishCallback: PublishCallback = proc(
      contentTopic: string, data: seq[byte]
  ) {.async.} =
    # Create a WakuMessage for the coordination data
    let msg = WakuMessage(
      payload: data,
      contentTopic: contentTopic,
      ephemeral: true, # Coordination messages don't need to be stored
      timestamp: getNowInNanosecondTime(),
    )

    # Delegate to node's publish API which handles topic derivation and relay publishing
    let res = await mix.publishMessage(msg)
    if res.isErr():
      warn "Failed to publish spam protection coordination message",
        contentTopic = contentTopic, error = res.error
      return

    trace "Published spam protection coordination message", contentTopic = contentTopic

  mix.mixRlnSpamProtection.setPublishCallback(publishCallback)
  info "Spam protection publish callback configured"

proc handleMessage*(
    mix: WakuMix, pubsubTopic: PubsubTopic, message: WakuMessage
) {.async, gcsafe.} =
  ## Handle incoming messages for spam protection coordination.
  ## This should be called from the relay handler for coordination content topics.
  if mix.mixRlnSpamProtection.isNil():
    return

  let contentTopic = message.contentTopic

  if contentTopic == mix.mixRlnSpamProtection.getMembershipContentTopic():
    # Handle membership update
    let res = await mix.mixRlnSpamProtection.handleMembershipUpdate(message.payload)
    if res.isErr:
      warn "Failed to handle membership update", error = res.error
    else:
      trace "Handled membership update"
  elif contentTopic == mix.mixRlnSpamProtection.getProofMetadataContentTopic():
    # Handle proof metadata for network-wide spam detection
    let res = mix.mixRlnSpamProtection.handleProofMetadata(message.payload)
    if res.isErr:
      warn "Failed to handle proof metadata", error = res.error
    else:
      trace "Handled proof metadata"

proc getSpamProtectionContentTopics*(mix: WakuMix): seq[string] =
  ## Get the content topics used by spam protection for coordination.
  ## Use these to set up relay subscriptions.
  if mix.mixRlnSpamProtection.isNil():
    return @[]
  return mix.mixRlnSpamProtection.getContentTopics()

method start*(mix: WakuMix) {.async.} =
  info "starting waku mix protocol"

  # Initialize and start spam protection
  if not mix.mixRlnSpamProtection.isNil():
    let initRes = await mix.mixRlnSpamProtection.init()
    if initRes.isErr:
      error "Failed to initialize spam protection", error = initRes.error
    else:
      # Set up publish callback after init
      mix.setupSpamProtectionCallbacks()

      let startRes = await mix.mixRlnSpamProtection.start()
      if startRes.isErr:
        error "Failed to start spam protection", error = startRes.error
      else:
        # Register self in the membership tree
        let regRes = await mix.mixRlnSpamProtection.registerSelf()
        if regRes.isErr:
          warn "Failed to register self in spam protection membership",
            error = regRes.error
        else:
          info "Spam protection started and self registered",
            membershipIndex = regRes.get()

  mix.nodePoolLoopHandle = mix.startMixNodePoolMgr()

method stop*(mix: WakuMix) {.async.} =
  # Stop spam protection
  if not mix.mixRlnSpamProtection.isNil():
    await mix.mixRlnSpamProtection.stop()
    info "Spam protection stopped"

  if mix.nodePoolLoopHandle.isNil():
    return
  await mix.nodePoolLoopHandle.cancelAndWait()
  mix.nodePoolLoopHandle = nil

# Mix Protocol
