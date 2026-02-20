{.used.}

import std/strutils
import chronos, testutils/unittests, stew/byteutils
import ../testlib/[common, testasync]
import
  waku, waku/[waku_node, waku_core, common/broker/broker_context, events/message_events]
import waku/api/api_conf, waku/factory/waku_conf

type ReceiveEventListenerManager = ref object
  brokerCtx: BrokerContext
  receivedListener: MessageReceivedEventListener
  receivedFuture: Future[void]
  receivedMessages: seq[WakuMessage]

proc newReceiveEventListenerManager(
    brokerCtx: BrokerContext
): ReceiveEventListenerManager =
  let manager = ReceiveEventListenerManager(brokerCtx: brokerCtx, receivedMessages: @[])
  manager.receivedFuture = newFuture[void]("receivedEvent")

  manager.receivedListener = MessageReceivedEvent.listen(
    brokerCtx,
    proc(event: MessageReceivedEvent) {.async: (raises: []).} =
      manager.receivedMessages.add(event.message)
      echo "RECEIVED EVENT TRIGGERED: contentTopic=", event.message.contentTopic

      if not manager.receivedFuture.finished():
        manager.receivedFuture.complete()
    ,
  ).valueOr:
    raiseAssert error

  return manager

proc teardown(manager: ReceiveEventListenerManager) =
  MessageReceivedEvent.dropListener(manager.brokerCtx, manager.receivedListener)

proc waitForEvent(
    manager: ReceiveEventListenerManager, timeout: Duration
): Future[bool] {.async.} =
  return await manager.receivedFuture.withTimeout(timeout)

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

suite "Waku API - Subscription Service":
  asyncTest "Subscription API, two relays with subscribe and receive message":
    var node1, node2: Waku

    lockNewGlobalBrokerContext:
      node1 = (await createNode(createApiNodeConf())).valueOr:
        raiseAssert error
      (await startWaku(addr node1)).isOkOr:
        raiseAssert "Failed to start node1"

    lockNewGlobalBrokerContext:
      node2 = (await createNode(createApiNodeConf())).valueOr:
        raiseAssert error
      (await startWaku(addr node2)).isOkOr:
        raiseAssert "Failed to start node2"

    let node2PeerInfo = node2.node.peerInfo.toRemotePeerInfo()
    await node1.node.connectToNodes(@[node2PeerInfo])

    await sleepAsync(2.seconds)

    let testTopic = ContentTopic("/waku/2/test-content/proto")

    (await node1.subscribe(testTopic)).isOkOr:
      raiseAssert "Node1 failed to subscribe: " & error

    (await node2.subscribe(testTopic)).isOkOr:
      raiseAssert "Node2 failed to subscribe: " & error

    await sleepAsync(2.seconds)

    let eventManager = newReceiveEventListenerManager(node2.brokerCtx)
    defer:
      eventManager.teardown()

    let envelope = MessageEnvelope.init(testTopic, "hello world payload")
    let sendResult = await node1.send(envelope)
    check sendResult.isOk()

    const eventTimeout = 5.seconds
    let receivedInTime = await eventManager.waitForEvent(eventTimeout)

    check receivedInTime == true
    check eventManager.receivedMessages.len == 1

    let receivedMsg = eventManager.receivedMessages[0]
    check receivedMsg.contentTopic == testTopic
    check string.fromBytes(receivedMsg.payload) == "hello world payload"

    (await node1.stop()).isOkOr:
      raiseAssert error
    (await node2.stop()).isOkOr:
      raiseAssert error
