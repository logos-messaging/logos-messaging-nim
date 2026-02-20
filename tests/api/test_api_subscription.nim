{.used.}

import std/[strutils, net, options]
import chronos, testutils/unittests, stew/byteutils
import libp2p/[peerid, peerinfo, multiaddress, crypto/crypto]
import ../testlib/[common, wakucore, wakunode, testasync]

import
  waku, waku/[waku_node, waku_core, common/broker/broker_context, events/message_events]
import waku/api/api_conf, waku/factory/waku_conf

const TestTimeout = chronos.seconds(10)
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

proc publishWhenMeshReady(
    publisher: WakuNode,
    pubsubTopic: PubsubTopic,
    contentTopic: ContentTopic,
    payload: seq[byte],
    maxRetries: int = 50,
    retryDelay: Duration = 200.milliseconds,
): Future[Result[int, string]] {.async.} =
  for _ in 0 ..< maxRetries:
    let msg = WakuMessage(
      payload: payload, contentTopic: contentTopic, version: 0, timestamp: now()
    )

    let publishRes = await publisher.publish(some(pubsubTopic), msg)
    if publishRes.isOk() and publishRes.value > 0:
      return publishRes

    await sleepAsync(retryDelay)

  return err("Timed out waiting for mesh")

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

    proc dummyHandler(
        topic: PubsubTopic, msg: WakuMessage
    ): Future[void] {.async, gcsafe.} =
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

    const testMessageStr = "Hello, world!"
    let msgPayload = testMessageStr.toBytes()

    discard (
      await publishWhenMeshReady(publisherNode, DefaultShard, testTopic, msgPayload)
    ).expect("Timed out waiting for mesh to stabilize")

    let receivedInTime = await eventManager.waitForEvents(TestTimeout)

    # Hard abort if these conditions aren't met to prevent an IndexDefect below
    require receivedInTime
    require eventManager.receivedMessages.len == 1

    let receivedMsg = eventManager.receivedMessages[0]
    check receivedMsg.contentTopic == testTopic
    check string.fromBytes(receivedMsg.payload) == testMessageStr
