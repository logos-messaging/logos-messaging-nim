{.used.}

import std/options, testutils/unittests, chronos, libp2p/crypto/crypto

import
  waku/[node/peer_manager, waku_core, waku_lightpush, waku_lightpush/client],
  ../testlib/wakucore,
  ./lightpush_utils

suite "Rate limited push service":
  asyncTest "push message with rate limit not violated":
    ## Setup
    let
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    ## Given
    var handlerFuture = newFuture[(string, WakuMessage)]()
    let handler: PushMessageHandler = proc(
        peer: PeerId, pubsubTopic: PubsubTopic, message: WakuMessage
    ): Future[WakuLightPushResult] {.async.} =
      handlerFuture.complete((pubsubTopic, message))
      return lightpushSuccessResult(1) # succeed to publish to 1 peer.

    let
      tokenPeriod = 500.millis
      server =
        await newTestWakuLightpushNode(serverSwitch, handler, some((3, tokenPeriod)))
      client = newTestWakuLightpushClient(clientSwitch)

    let serverPeerId = serverSwitch.peerInfo.toRemotePeerInfo()

    let sendMsgProc = proc(): Future[void] {.async.} =
      let message = fakeWakuMessage()

      handlerFuture = newFuture[(string, WakuMessage)]()
      let requestRes =
        await client.publish(some(DefaultPubsubTopic), message, serverPeerId)

      check await handlerFuture.withTimeout(50.millis)

      check:
        requestRes.isOk()
        handlerFuture.finished()

      let (handledMessagePubsubTopic, handledMessage) = handlerFuture.read()

      check:
        handledMessagePubsubTopic == DefaultPubsubTopic
        handledMessage == message

    let waitInBetweenFor = 20.millis

    # Test cannot be too explicit about the time when the TokenBucket resets
    # the internal timer, although in normal use there is no use case to care about it.
    var firstWaitExtend = 300.millis

    for runCnt in 0 ..< 3:
      let startTime = Moment.now()
      for testCnt in 0 ..< 3:
        await sendMsgProc()
        await sleepAsync(20.millis)

      var endTime = Moment.now()
      var elapsed: Duration = (endTime - startTime)
      await sleepAsync(tokenPeriod - elapsed + firstWaitExtend)
      firstWaitExtend = 100.millis

    ## Cleanup
    await allFutures(clientSwitch.stop(), serverSwitch.stop())

  asyncTest "push message with rate limit reject":
    ## Setup
    let
      serverSwitch = newTestSwitch()
      clientSwitch = newTestSwitch()

    await allFutures(serverSwitch.start(), clientSwitch.start())

    ## Given
    var handlerFuture = newFuture[(string, WakuMessage)]()
    let handler = proc(
        peer: PeerId, pubsubTopic: PubsubTopic, message: WakuMessage
    ): Future[WakuLightPushResult] {.async.} =
      handlerFuture.complete((pubsubTopic, message))
      return lightpushSuccessResult(1)

    let
      server =
        await newTestWakuLightpushNode(serverSwitch, handler, some((3, 500.millis)))
      client = newTestWakuLightpushClient(clientSwitch)

    let serverPeerId = serverSwitch.peerInfo.toRemotePeerInfo()
    let topic = DefaultPubsubTopic

    let successProc = proc(): Future[void] {.async.} =
      let message = fakeWakuMessage()
      handlerFuture = newFuture[(string, WakuMessage)]()
      let requestRes =
        await client.publish(some(DefaultPubsubTopic), message, serverPeerId)
      discard await handlerFuture.withTimeout(10.millis)

      check:
        requestRes.isOk()
        handlerFuture.finished()
      let (handledMessagePubsubTopic, handledMessage) = handlerFuture.read()
      check:
        handledMessagePubsubTopic == DefaultPubsubTopic
        handledMessage == message

    let rejectProc = proc(): Future[void] {.async.} =
      let message = fakeWakuMessage()
      handlerFuture = newFuture[(string, WakuMessage)]()
      let requestRes =
        await client.publish(some(DefaultPubsubTopic), message, serverPeerId)
      discard await handlerFuture.withTimeout(10.millis)

      check:
        requestRes.isErr()
        requestRes.error.code == LightPushErrorCode.TOO_MANY_REQUESTS
        requestRes.error.desc == some(TooManyRequestsMessage)

    for testCnt in 0 .. 2:
      await successProc()
      await sleepAsync(5.millis)

    await rejectProc()

    await sleepAsync(500.millis)

    ## next one shall succeed due to the rate limit time window has passed
    await successProc()

    ## Cleanup
    await allFutures(clientSwitch.stop(), serverSwitch.stop())
