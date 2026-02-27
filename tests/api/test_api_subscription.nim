{.used.}

import std/[strutils, net, options]
import chronos, testutils/unittests, stew/byteutils
import libp2p/[peerid, peerinfo, multiaddress, crypto/crypto]
import ../testlib/[common, wakucore, wakunode, testasync]

import
  waku,
  waku/[
    waku_node,
    waku_core,
    common/broker/broker_context,
    events/message_events,
    waku_relay/protocol,
  ]
import waku/api/api_conf, waku/factory/waku_conf

# TODO: Edge testing (after MAPI edge support is completed)

const TestTimeout = chronos.seconds(10)
const NegativeTestTimeout = chronos.seconds(2)
const DefaultShard = PubsubTopic("/waku/2/rs/1/0")

type ReceiveEventListenerManager = ref object
  brokerCtx: BrokerContext
  receivedListener: MessageReceivedEventListener
  receivedEvent: AsyncEvent
  receivedMessages: seq[WakuMessage]
  targetCount: int

proc newReceiveEventListenerManager(
    brokerCtx: BrokerContext, expectedCount: int = 1
): ReceiveEventListenerManager =
  let manager = ReceiveEventListenerManager(
    brokerCtx: brokerCtx, receivedMessages: @[], targetCount: expectedCount
  )
  manager.receivedEvent = newAsyncEvent()

  manager.receivedListener = MessageReceivedEvent
    .listen(
      brokerCtx,
      proc(event: MessageReceivedEvent) {.async: (raises: []).} =
        manager.receivedMessages.add(event.message)

        if manager.receivedMessages.len >= manager.targetCount:
          manager.receivedEvent.fire()
      ,
    )
    .expect("Failed to listen to MessageReceivedEvent")

  return manager

proc teardown(manager: ReceiveEventListenerManager) =
  MessageReceivedEvent.dropListener(manager.brokerCtx, manager.receivedListener)

proc waitForEvents(
    manager: ReceiveEventListenerManager, timeout: Duration
): Future[bool] {.async.} =
  return await manager.receivedEvent.wait().withTimeout(timeout)

proc createApiNodeConf(mode: WakuMode = WakuMode.Core): NodeConfig =
  let netConf = NetworkingConfig(listenIpv4: "0.0.0.0", p2pTcpPort: 0, discv5UdpPort: 0)
  result = NodeConfig.init(
    mode = mode,
    protocolsConfig = ProtocolsConfig.init(
      entryNodes = @[],
      clusterId = 1,
      autoShardingConfig = AutoShardingConfig(numShardsInCluster: 1),
    ),
    networkingConfig = netConf,
    p2pReliability = true,
  )

proc setupSubscriberNode(conf: NodeConfig): Future[Waku] {.async.} =
  var node: Waku
  lockNewGlobalBrokerContext:
    node = (await createNode(conf)).expect("Failed to create subscriber node")
    (await startWaku(addr node)).expect("Failed to start subscriber node")
  return node

proc waitForMesh*(node: WakuNode, shard: PubsubTopic) {.async.} =
  for _ in 0 ..< 50:
    if node.wakuRelay.getNumPeersInMesh(shard).valueOr(0) > 0:
      return
    await sleepAsync(100.milliseconds)
  raise newException(ValueError, "GossipSub Mesh failed to stabilize")

proc publishWhenMeshReady(
    publisher: WakuNode,
    pubsubTopic: PubsubTopic,
    contentTopic: ContentTopic,
    payload: seq[byte],
): Future[Result[int, string]] {.async.} =
  await waitForMesh(publisher, pubsubTopic)

  let msg = WakuMessage(
    payload: payload, contentTopic: contentTopic, version: 0, timestamp: now()
  )
  return await publisher.publish(some(pubsubTopic), msg)

suite "Messaging API, SubscriptionService":
  var
    publisherNode {.threadvar.}: WakuNode
    publisherPeerInfo {.threadvar.}: RemotePeerInfo
    publisherPeerId {.threadvar.}: PeerId

    subscriberNode {.threadvar.}: Waku

  asyncSetup:
    lockNewGlobalBrokerContext:
      publisherNode =
        newTestWakuNode(generateSecp256k1Key(), parseIpAddress("0.0.0.0"), Port(0))

      publisherNode.mountMetadata(1, @[0'u16]).expect("Failed to mount metadata")
      (await publisherNode.mountRelay()).expect("Failed to mount relay")
      await publisherNode.mountLibp2pPing()
      await publisherNode.start()

    publisherPeerInfo = publisherNode.peerInfo.toRemotePeerInfo()
    publisherPeerId = publisherNode.peerInfo.peerId

    proc dummyHandler(topic: PubsubTopic, msg: WakuMessage) {.async, gcsafe.} =
      discard

    publisherNode.subscribe((kind: PubsubSub, topic: DefaultShard), dummyHandler).expect(
      "Failed to subscribe publisherNode"
    )

  asyncTeardown:
    if not subscriberNode.isNil():
      (await subscriberNode.stop()).expect("Failed to stop subscriber node")
      subscriberNode = nil

    if not publisherNode.isNil():
      await publisherNode.stop()
      publisherNode = nil

  asyncTest "Subscription API, relay node auto subscribe and receive message":
    subscriberNode = await setupSubscriberNode(createApiNodeConf(WakuMode.Core))
    await subscriberNode.node.connectToNodes(@[publisherPeerInfo])
    let testTopic = ContentTopic("/waku/2/test-content/proto")

    (await subscriberNode.subscribe(testTopic)).expect(
      "subscriberNode failed to subscribe"
    )

    let eventManager = newReceiveEventListenerManager(subscriberNode.brokerCtx, 1)
    defer:
      eventManager.teardown()

    discard (
      await publishWhenMeshReady(
        publisherNode, DefaultShard, testTopic, "Hello, world!".toBytes()
      )
    ).expect("Publish failed")

    require await eventManager.waitForEvents(TestTimeout)
    require eventManager.receivedMessages.len == 1
    check eventManager.receivedMessages[0].contentTopic == testTopic

  asyncTest "Subscription API, relay node ignores unsubscribed content topics on same shard":
    subscriberNode = await setupSubscriberNode(createApiNodeConf(WakuMode.Core))
    await subscriberNode.node.connectToNodes(@[publisherPeerInfo])

    let subbedTopic = ContentTopic("/waku/2/subbed-topic/proto")
    let ignoredTopic = ContentTopic("/waku/2/ignored-topic/proto")
    (await subscriberNode.subscribe(subbedTopic)).expect("failed to subscribe")

    let eventManager = newReceiveEventListenerManager(subscriberNode.brokerCtx, 1)
    defer:
      eventManager.teardown()

    discard (
      await publishWhenMeshReady(
        publisherNode, DefaultShard, ignoredTopic, "Ghost Msg".toBytes()
      )
    ).expect("Publish failed")

    check not await eventManager.waitForEvents(NegativeTestTimeout)
    check eventManager.receivedMessages.len == 0

  asyncTest "Subscription API, relay node unsubscribe stops message receipt":
    subscriberNode = await setupSubscriberNode(createApiNodeConf(WakuMode.Core))
    await subscriberNode.node.connectToNodes(@[publisherPeerInfo])
    let testTopic = ContentTopic("/waku/2/unsub-test/proto")

    (await subscriberNode.subscribe(testTopic)).expect("failed to subscribe")
    subscriberNode.unsubscribe(testTopic).expect("failed to unsubscribe")

    let eventManager = newReceiveEventListenerManager(subscriberNode.brokerCtx, 1)
    defer:
      eventManager.teardown()

    discard (
      await publishWhenMeshReady(
        publisherNode, DefaultShard, testTopic, "Should be dropped".toBytes()
      )
    ).expect("Publish failed")

    check not await eventManager.waitForEvents(NegativeTestTimeout)
    check eventManager.receivedMessages.len == 0

  asyncTest "Subscription API, overlapping topics on same shard maintain correct isolation":
    subscriberNode = await setupSubscriberNode(createApiNodeConf(WakuMode.Core))
    await subscriberNode.node.connectToNodes(@[publisherPeerInfo])

    let topicA = ContentTopic("/waku/2/topic-a/proto")
    let topicB = ContentTopic("/waku/2/topic-b/proto")
    (await subscriberNode.subscribe(topicA)).expect("failed to sub A")
    (await subscriberNode.subscribe(topicB)).expect("failed to sub B")

    let eventManager = newReceiveEventListenerManager(subscriberNode.brokerCtx, 1)
    defer:
      eventManager.teardown()

    await waitForMesh(publisherNode, DefaultShard)

    subscriberNode.unsubscribe(topicA).expect("failed to unsub A")

    discard (
      await publisherNode.publish(
        some(DefaultShard),
        WakuMessage(
          payload: "Dropped Message".toBytes(),
          contentTopic: topicA,
          version: 0,
          timestamp: now(),
        ),
      )
    ).expect("Publish A failed")

    discard (
      await publisherNode.publish(
        some(DefaultShard),
        WakuMessage(
          payload: "Kept Msg".toBytes(),
          contentTopic: topicB,
          version: 0,
          timestamp: now(),
        ),
      )
    ).expect("Publish B failed")

    require await eventManager.waitForEvents(TestTimeout)
    require eventManager.receivedMessages.len == 1
    check eventManager.receivedMessages[0].contentTopic == topicB

  asyncTest "Subscription API, redundant subs tolerated and subs are removed":
    subscriberNode = await setupSubscriberNode(createApiNodeConf(WakuMode.Core))
    await subscriberNode.node.connectToNodes(@[publisherPeerInfo])
    let glitchTopic = ContentTopic("/waku/2/glitch/proto")

    (await subscriberNode.subscribe(glitchTopic)).expect("failed to sub")
    (await subscriberNode.subscribe(glitchTopic)).expect("failed to double sub")
    subscriberNode.unsubscribe(glitchTopic).expect("failed to unsub")

    let eventManager = newReceiveEventListenerManager(subscriberNode.brokerCtx, 1)
    defer:
      eventManager.teardown()

    discard (
      await publishWhenMeshReady(
        publisherNode, DefaultShard, glitchTopic, "Ghost Msg".toBytes()
      )
    ).expect("Publish failed")

    check not await eventManager.waitForEvents(NegativeTestTimeout)
    check eventManager.receivedMessages.len == 0

  asyncTest "Subscription API, resubscribe to an unsubscribed topic":
    subscriberNode = await setupSubscriberNode(createApiNodeConf(WakuMode.Core))
    await subscriberNode.node.connectToNodes(@[publisherPeerInfo])
    let testTopic = ContentTopic("/waku/2/resub-test/proto")

    # Subscribe
    (await subscriberNode.subscribe(testTopic)).expect("Initial sub failed")

    var eventManager = newReceiveEventListenerManager(subscriberNode.brokerCtx, 1)
    discard (
      await publishWhenMeshReady(
        publisherNode, DefaultShard, testTopic, "Msg 1".toBytes()
      )
    ).expect("Pub 1 failed")

    require await eventManager.waitForEvents(TestTimeout)
    eventManager.teardown()

    # Unsubscribe and verify teardown
    subscriberNode.unsubscribe(testTopic).expect("Unsub failed")
    eventManager = newReceiveEventListenerManager(subscriberNode.brokerCtx, 1)

    discard (
      await publisherNode.publish(
        some(DefaultShard),
        WakuMessage(
          payload: "Ghost".toBytes(),
          contentTopic: testTopic,
          version: 0,
          timestamp: now(),
        ),
      )
    ).expect("Ghost pub failed")

    check not await eventManager.waitForEvents(NegativeTestTimeout)
    eventManager.teardown()

    # Resubscribe
    (await subscriberNode.subscribe(testTopic)).expect("Resub failed")
    eventManager = newReceiveEventListenerManager(subscriberNode.brokerCtx, 1)

    discard (
      await publishWhenMeshReady(
        publisherNode, DefaultShard, testTopic, "Msg 2".toBytes()
      )
    ).expect("Pub 2 failed")

    require await eventManager.waitForEvents(TestTimeout)
    check eventManager.receivedMessages[0].payload == "Msg 2".toBytes()
