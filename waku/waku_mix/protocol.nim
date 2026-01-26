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

    # Strip /p2p/ suffix for mix protocol - it only needs network address
    var networkAddr = multiAddr
    try:
      if multiAddr.contains(multiCodec("p2p")).get():
        let parts = multiAddr.items().toSeq()
        var addrWithoutP2P = MultiAddress()
        for i in 0 ..< parts.len - 1:
          let part = parts[i].valueOr:
            continue
          addrWithoutP2P = addrWithoutP2P & part
        networkAddr = addrWithoutP2P
    except CatchableError as e:
      warn "Failed to strip /p2p/ from multiaddr", error = e.msg
      # Continue with full multiaddr

    mixNodes[peerId] =
      MixPubInfo.init(peerId, networkAddr, node.pubKey, peerPubKey.skkey)

    peermgr.addPeer(
      RemotePeerInfo.init(peerId, @[networkAddr], mixPubKey = some(node.pubKey))
    )
  mix_pool_size.set(len(mixNodes))
  debug "using mix bootstrap nodes", count = mixNodes.len
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
  trace "mixPubKey", mixPubKey = mixPubKey
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

  # Initialize spam protection with persistent credentials
  # Use peerID in keystore path so multiple peers can run from same directory
  # Tree path is shared across all nodes to maintain the full membership set
  let peerId = peermgr.switch.peerInfo.peerId
  var spamProtectionConfig = defaultConfig()
  spamProtectionConfig.keystorePath = "rln_keystore_" & $peerId & ".json"
  spamProtectionConfig.keystorePassword = "mix-rln-password"
  # rlnResourcesPath left empty to use bundled resources (via "tree_height_/" placeholder)

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
  trace "Spam protection publish callback configured"

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

      # Persist tree after membership changes (temporary solution)
      # TODO: Replace with proper persistence strategy (e.g., periodic snapshots)
      let saveRes = mix.mixRlnSpamProtection.saveTree()
      if saveRes.isErr:
        debug "Failed to save tree after membership update", error = saveRes.error
      else:
        trace "Saved tree after membership update"
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

proc saveSpamProtectionTree*(mix: WakuMix): Result[void, string] =
  ## Save the spam protection membership tree to disk.
  ## This allows preserving the tree state across restarts.
  if mix.mixRlnSpamProtection.isNil():
    return err("Spam protection not initialized")

  mix.mixRlnSpamProtection.saveTree().mapErr(
    proc(e: string): string =
      e
  )

proc loadSpamProtectionTree*(mix: WakuMix): Result[void, string] =
  ## Load the spam protection membership tree from disk.
  ## Call this before init() to restore tree state from previous runs.
  ## TODO: This is a temporary solution. Ideally nodes should sync tree state
  ## via a store query for historical membership messages or via dedicated
  ## tree sync protocol.
  if mix.mixRlnSpamProtection.isNil():
    return err("Spam protection not initialized")

  mix.mixRlnSpamProtection.loadTree().mapErr(
    proc(e: string): string =
      e
  )

method start*(mix: WakuMix) {.async.} =
  info "starting waku mix protocol"

  # Set up spam protection callbacks and start
  if not mix.mixRlnSpamProtection.isNil():
    # Initialize spam protection (MixProtocol.init() does NOT call init() on the plugin)
    let initRes = await mix.mixRlnSpamProtection.init()
    if initRes.isErr:
      error "Failed to initialize spam protection", error = initRes.error
    else:
      # Load existing tree to sync with other members
      # This should be done after init() (which loads credentials)
      # but before registerSelf() (which adds us to the tree)
      let loadRes = mix.mixRlnSpamProtection.loadTree()
      if loadRes.isErr:
        debug "No existing tree found or failed to load, starting fresh",
          error = loadRes.error
      else:
        debug "Loaded existing spam protection membership tree from disk"

      # Restore our credentials to the tree (after tree load, whether it succeeded or not)
      # This ensures our member is in the tree if we have an index from keystore
      let restoreRes = mix.mixRlnSpamProtection.restoreCredentialsToTree()
      if restoreRes.isErr:
        error "Failed to restore credentials to tree", error = restoreRes.error

      # Set up publish callback (must be before start so registerSelf can use it)
      mix.setupSpamProtectionCallbacks()

      let startRes = await mix.mixRlnSpamProtection.start()
      if startRes.isErr:
        error "Failed to start spam protection", error = startRes.error
      else:
        # Register self to broadcast membership to the network
        let registerRes = await mix.mixRlnSpamProtection.registerSelf()
        if registerRes.isErr:
          error "Failed to register spam protection credentials",
            error = registerRes.error
        else:
          debug "Registered spam protection credentials", index = registerRes.get()

        # Save tree to persist membership state
        let saveRes = mix.mixRlnSpamProtection.saveTree()
        if saveRes.isErr:
          warn "Failed to save spam protection tree", error = saveRes.error
        else:
          trace "Saved spam protection tree to disk"

  mix.nodePoolLoopHandle = mix.startMixNodePoolMgr()

method stop*(mix: WakuMix) {.async.} =
  # Stop spam protection
  if not mix.mixRlnSpamProtection.isNil():
    await mix.mixRlnSpamProtection.stop()
    debug "Spam protection stopped"

  if mix.nodePoolLoopHandle.isNil():
    return
  await mix.nodePoolLoopHandle.cancelAndWait()
  mix.nodePoolLoopHandle = nil

# Mix Protocol
