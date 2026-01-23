{.used.}

import std/strutils
import chronos, testutils/unittests, stew/byteutils, libp2p/[switch, peerinfo]
import ../testlib/[common, wakucore, wakunode, testasync]
import ../waku_archive/archive_utils
import
  waku, waku/[waku_node, waku_core, waku_relay/protocol, common/broker/broker_context]
import waku/api/api_conf, waku/factory/waku_conf

suite "Waku API - Send":
  var
    relayNode1 {.threadvar.}: WakuNode
    relayNode1PeerInfo {.threadvar.}: RemotePeerInfo
    relayNode1PeerId {.threadvar.}: PeerId

    relayNode2 {.threadvar.}: WakuNode
    relayNode2PeerInfo {.threadvar.}: RemotePeerInfo
    relayNode2PeerId {.threadvar.}: PeerId

    lightpushNode {.threadvar.}: WakuNode
    lightpushNodePeerInfo {.threadvar.}: RemotePeerInfo
    lightpushNodePeerId {.threadvar.}: PeerId

    storeNode {.threadvar.}: WakuNode
    storeNodePeerInfo {.threadvar.}: RemotePeerInfo
    storeNodePeerId {.threadvar.}: PeerId

  asyncSetup:
    lockNewGlobalBrokerContext:
      relayNode1 =
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
      relayNode1.mountMetadata(1, @[0'u16]).isOkOr:
        raiseAssert "Failed to mount metadata: " & error
      (await relayNode1.mountRelay()).isOkOr:
        raiseAssert "Failed to mount relay"
      await relayNode1.mountLibp2pPing()
      await relayNode1.start()

    lockNewGlobalBrokerContext:
      relayNode2 =
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
      relayNode2.mountMetadata(1, @[0'u16]).isOkOr:
        raiseAssert "Failed to mount metadata: " & error
      (await relayNode2.mountRelay()).isOkOr:
        raiseAssert "Failed to mount relay"
      await relayNode2.mountLibp2pPing()
      await relayNode2.start()

    lockNewGlobalBrokerContext:
      lightpushNode =
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
      lightpushNode.mountMetadata(1, @[0'u16]).isOkOr:
        raiseAssert "Failed to mount metadata: " & error
      (await lightpushNode.mountRelay()).isOkOr:
        raiseAssert "Failed to mount relay"
      (await lightpushNode.mountLightPush()).isOkOr:
        raiseAssert "Failed to mount lightpush"
      await lightpushNode.mountLibp2pPing()
      await lightpushNode.start()

    lockNewGlobalBrokerContext:
      storeNode =
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))
      storeNode.mountMetadata(1, @[0'u16]).isOkOr:
        raiseAssert "Failed to mount metadata: " & error
      (await storeNode.mountRelay()).isOkOr:
        raiseAssert "Failed to mount relay"
      # Mount archive so store can persist messages
      let archiveDriver = newSqliteArchiveDriver()
      storeNode.mountArchive(archiveDriver).isOkOr:
        raiseAssert "Failed to mount archive: " & error
      await storeNode.mountStore()
      await storeNode.mountLibp2pPing()
      await storeNode.start()

    relayNode1PeerInfo = relayNode1.peerInfo.toRemotePeerInfo()
    relayNode1PeerId = relayNode1.peerInfo.peerId

    relayNode2PeerInfo = relayNode2.peerInfo.toRemotePeerInfo()
    relayNode2PeerId = relayNode2.peerInfo.peerId

    lightpushNodePeerInfo = lightpushNode.peerInfo.toRemotePeerInfo()
    lightpushNodePeerId = lightpushNode.peerInfo.peerId

    storeNodePeerInfo = storeNode.peerInfo.toRemotePeerInfo()
    storeNodePeerId = storeNode.peerInfo.peerId

    # Subscribe all relay nodes to the default shard topic
    const testPubsubTopic = PubsubTopic("/waku/2/rs/1/0")
    proc dummyHandler(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
      discard

    relayNode1.subscribe((kind: PubsubSub, topic: testPubsubTopic), dummyHandler).isOkOr:
      raiseAssert "Failed to subscribe relayNode1: " & error
    relayNode2.subscribe((kind: PubsubSub, topic: testPubsubTopic), dummyHandler).isOkOr:
      raiseAssert "Failed to subscribe relayNode2: " & error

    lightpushNode.subscribe((kind: PubsubSub, topic: testPubsubTopic), dummyHandler).isOkOr:
      raiseAssert "Failed to subscribe lightpushNode: " & error
    storeNode.subscribe((kind: PubsubSub, topic: testPubsubTopic), dummyHandler).isOkOr:
      raiseAssert "Failed to subscribe storeNode: " & error

    # Subscribe all relay nodes to the default shard topic
    await relayNode1.connectToNodes(@[relayNode2PeerInfo, storeNodePeerInfo])
    await lightpushNode.connectToNodes(@[relayNode2PeerInfo])

  asyncTeardown:
    await allFutures(
      relayNode1.stop(), relayNode2.stop(), lightpushNode.stop(), storeNode.stop()
    )

  asyncTest "Check API availability (unhealthy node)":
    # Create a node config that doesn't start or has no peers
    let nodeConfig = NodeConfig.init(
      mode = WakuMode.Core,
      protocolsConfig = ProtocolsConfig.init(
        entryNodes = @[],
        clusterId = 1,
        autoShardingConfig = AutoShardingConfig(numShardsInCluster: 1),
      ),
    )

    let wakuConfRes = toWakuConf(nodeConfig)

    ## Then
    require wakuConfRes.isOk()
    let wakuConf = wakuConfRes.get()
    require wakuConf.validate().isOk()
    check:
      wakuConf.clusterId == 1
      wakuConf.shardingConf.numShardsInCluster == 1

    var node: Waku
    lockNewGlobalBrokerContext:
      node = (await createNode(nodeConfig)).valueOr:
        raiseAssert error
      (await startWaku(addr node)).isOkOr:
        raiseAssert "Failed to start Waku node: " & error
      # node is not connected !

    let envelope = MessageEnvelope.init(
      ContentTopic("/waku/2/default-content/proto"), "test payload"
    )

    let sendResult = await node.send(envelope)

    check sendResult.isErr() # Depending on implementation, it might say "not healthy"
    check sendResult.error().contains("not healthy")

    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error

  asyncTest "Check API availability (healthy node)":
    # Create a node config that doesn't start or has no peers
    let nodeConfig = NodeConfig.init(
      mode = WakuMode.Core,
      protocolsConfig = ProtocolsConfig.init(
        entryNodes = @[],
        clusterId = 1,
        autoShardingConfig = AutoShardingConfig(numShardsInCluster: 1),
      ),
      p2pReliability = true,
    )

    var node: Waku
    lockNewGlobalBrokerContext:
      node = (await createNode(nodeConfig)).valueOr:
        raiseAssert error
      (await startWaku(addr node)).isOkOr:
        raiseAssert "Failed to start Waku node: " & error

      await node.node.connectToNodes(
        @[relayNode1PeerInfo, lightpushNodePeerInfo, storeNodePeerInfo]
      )

    let sentEventFuture = newFuture[void]("sentEvent")
    let sentListener = MessageSentEvent.listen(
      node.brokerCtx,
      proc(event: MessageSentEvent) {.async: (raises: []).} =
        echo "SENT EVENT TRIGGERED: requestId=", event.requestId
        if not sentEventFuture.finished():
          sentEventFuture.complete()
      ,
    ).valueOr:
      raiseAssert error

    let errorEventFuture = newFuture[void]("errorEvent")
    let errorListener = MessageErrorEvent.listen(
      node.brokerCtx,
      proc(event: MessageErrorEvent) {.async: (raises: []).} =
        echo "ERROR EVENT TRIGGERED: ", event.error
        if not errorEventFuture.finished():
          errorEventFuture.fail(
            newException(CatchableError, "Error event triggered: " & event.error)
          )
      ,
    ).valueOr:
      raiseAssert error

    let propagatedEventFuture = newFuture[void]("propagatedEvent")
    let propagatedListener = MessagePropagatedEvent.listen(
      node.brokerCtx,
      proc(event: MessagePropagatedEvent) {.async: (raises: []).} =
        echo "PROPAGATED EVENT TRIGGERED: requestId=", event.requestId
        if not propagatedEventFuture.finished():
          propagatedEventFuture.complete()
      ,
    ).valueOr:
      raiseAssert error
    defer:
      MessageSentEvent.dropListener(node.brokerCtx, sentListener)
      MessageErrorEvent.dropListener(node.brokerCtx, errorListener)
      MessagePropagatedEvent.dropListener(node.brokerCtx, propagatedListener)

    let envelope = MessageEnvelope.init(
      ContentTopic("/waku/2/default-content/proto"), "test payload"
    )

    let sendResult = await node.send(envelope)

    check sendResult.isOk() # Depending on implementation, it might say "not healthy"

    # Wait for events with timeout
    const eventTimeout = 10.seconds
    discard await allFutures(sentEventFuture, propagatedEventFuture, errorEventFuture)
    .withTimeout(eventTimeout)

    check sentEventFuture.completed()
    check propagatedEventFuture.completed()
    check not errorEventFuture.failed()

    (await node.stop()).isOkOr:
      raiseAssert "Failed to stop node: " & error
