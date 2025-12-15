{.pragma: exported, exportc, cdecl, raises: [].}
{.pragma: callback, cdecl, raises: [], gcsafe.}
{.passc: "-fPIC".}

import std/[options, atomics, os, net, locks]
import chronicles, chronos, chronos/threadsync, taskpools/channels_spsc_single, results
import
  waku/common/logging,
  waku/factory/waku,
  waku/node/peer_manager,
  waku/waku_relay/protocol,
  waku/node/health_monitor/topic_health,
  waku/waku_core/[topics/pubsub_topic, message],
  ./waku_thread_requests/[waku_thread_request, requests/debug_node_request],
  ./ffi_types,
  ./events/[
    json_message_event, json_topic_health_change_event, json_connection_change_event,
    json_waku_not_responding_event,
  ]

type WakuContext* = object
  wakuThread: Thread[(ptr WakuContext)]
  watchdogThread: Thread[(ptr WakuContext)]
    # monitors the Waku thread and notifies the Waku SDK consumer if it hangs
  lock: Lock
  reqChannel: ChannelSPSCSingle[ptr WakuThreadRequest]
  reqSignal: ThreadSignalPtr
    # to inform The Waku Thread (a.k.a TWT) that a new request is sent
  reqReceivedSignal: ThreadSignalPtr
    # to inform the main thread that the request is rx by TWT
  userData*: pointer
  eventCallback*: pointer
  eventUserdata*: pointer
  running: Atomic[bool] # To control when the threads are running

const git_version* {.strdefine.} = "n/a"
const versionString = "version / git commit hash: " & waku.git_version

template callEventCallback(ctx: ptr WakuContext, eventName: string, body: untyped) =
  if isNil(ctx[].eventCallback):
    error eventName & " - eventCallback is nil"
    return

  foreignThreadGc:
    try:
      let event = body
      cast[WakuCallBack](ctx[].eventCallback)(
        RET_OK, unsafeAddr event[0], cast[csize_t](len(event)), ctx[].eventUserData
      )
    except Exception, CatchableError:
      let msg =
        "Exception " & eventName & " when calling 'eventCallBack': " &
        getCurrentExceptionMsg()
      cast[WakuCallBack](ctx[].eventCallback)(
        RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), ctx[].eventUserData
      )

proc onConnectionChange*(ctx: ptr WakuContext): ConnectionChangeHandler =
  return proc(peerId: PeerId, peerEvent: PeerEventKind) {.async.} =
    callEventCallback(ctx, "onConnectionChange"):
      $JsonConnectionChangeEvent.new($peerId, peerEvent)

proc onReceivedMessage*(ctx: ptr WakuContext): WakuRelayHandler =
  return proc(pubsubTopic: PubsubTopic, msg: WakuMessage) {.async.} =
    callEventCallback(ctx, "onReceivedMessage"):
      $JsonMessageEvent.new(pubsubTopic, msg)

proc onTopicHealthChange*(ctx: ptr WakuContext): TopicHealthChangeHandler =
  return proc(pubsubTopic: PubsubTopic, topicHealth: TopicHealth) {.async.} =
    callEventCallback(ctx, "onTopicHealthChange"):
      $JsonTopicHealthChangeEvent.new(pubsubTopic, topicHealth)

proc onWakuNotResponding*(ctx: ptr WakuContext) =
  callEventCallback(ctx, "onWakuNotResponsive"):
    $JsonWakuNotRespondingEvent.new()

proc sendRequestToWakuThread*(
    ctx: ptr WakuContext,
    reqType: RequestType,
    reqContent: pointer,
    callback: WakuCallBack,
    userData: pointer,
    timeout = InfiniteDuration,
): Result[void, string] =
  ctx.lock.acquire()
  # This lock is only necessary while we use a SP Channel and while the signalling
  # between threads assumes that there aren't concurrent requests.
  # Rearchitecting the signaling + migrating to a MP Channel will allow us to receive
  # requests concurrently and spare us the need of locks
  defer:
    ctx.lock.release()

  let req = WakuThreadRequest.createShared(reqType, reqContent, callback, userData)
  ## Sending the request
  let sentOk = ctx.reqChannel.trySend(req)
  if not sentOk:
    deallocShared(req)
    return err("Couldn't send a request to the waku thread: " & $req[])

  let fireSync = ctx.reqSignal.fireSync().valueOr:
    deallocShared(req)
    return err("failed fireSync: " & $error)

  if not fireSync:
    deallocShared(req)
    return err("Couldn't fireSync in time")

  ## wait until the Waku Thread properly received the request
  ctx.reqReceivedSignal.waitSync(timeout).isOkOr:
    deallocShared(req)
    return err("Couldn't receive reqReceivedSignal signal")

  ## Notice that in case of "ok", the deallocShared(req) is performed by the Waku Thread in the
  ## process proc. See the 'waku_thread_request.nim' module for more details.
  ok()

proc watchdogThreadBody(ctx: ptr WakuContext) {.thread.} =
  ## Watchdog thread that monitors the Waku thread and notifies the library user if it hangs.

  let watchdogRun = proc(ctx: ptr WakuContext) {.async.} =
    const WatchdogStartDelay = 10.seconds
    const WatchdogTimeinterval = 1.seconds
    const WakuNotRespondingTimeout = 3.seconds

    # Give time for the node to be created and up before sending watchdog requests
    await sleepAsync(WatchdogStartDelay)
    while true:
      await sleepAsync(WatchdogTimeinterval)

      if ctx.running.load == false:
        info "Watchdog thread exiting because WakuContext is not running"
        break

      let wakuCallback = proc(
          callerRet: cint, msg: ptr cchar, len: csize_t, userData: pointer
      ) {.cdecl, gcsafe, raises: [].} =
        discard ## Don't do anything. Just respecting the callback signature.
      const nilUserData = nil

      trace "Sending watchdog request to Waku thread"

      sendRequestToWakuThread(
        ctx,
        RequestType.DEBUG,
        DebugNodeRequest.createShared(DebugNodeMsgType.CHECK_WAKU_NOT_BLOCKED),
        wakuCallback,
        nilUserData,
        WakuNotRespondingTimeout,
      ).isOkOr:
        error "Failed to send watchdog request to Waku thread", error = $error
        onWakuNotResponding(ctx)

  waitFor watchdogRun(ctx)

proc wakuThreadBody(ctx: ptr WakuContext) {.thread.} =
  ## Waku thread that attends library user requests (stop, connect_to, etc.)

  logging.setupLog(logging.LogLevel.DEBUG, logging.LogFormat.TEXT)

  let wakuRun = proc(ctx: ptr WakuContext) {.async.} =
    var waku: Waku
    while true:
      await ctx.reqSignal.wait()

      if ctx.running.load == false:
        break

      ## Trying to get a request from the libwaku requestor thread
      var request: ptr WakuThreadRequest
      let recvOk = ctx.reqChannel.tryRecv(request)
      if not recvOk:
        error "waku thread could not receive a request"
        continue

      ## Handle the request
      asyncSpawn WakuThreadRequest.process(request, addr waku)

      ctx.reqReceivedSignal.fireSync().isOkOr:
        error "could not fireSync back to requester thread", error = error

  waitFor wakuRun(ctx)

proc createWakuContext*(): Result[ptr WakuContext, string] =
  ## This proc is called from the main thread and it creates
  ## the Waku working thread.
  var ctx = createShared(WakuContext, 1)
  ctx.reqSignal = ThreadSignalPtr.new().valueOr:
    return err("couldn't create reqSignal ThreadSignalPtr")
  ctx.reqReceivedSignal = ThreadSignalPtr.new().valueOr:
    return err("couldn't create reqReceivedSignal ThreadSignalPtr")
  ctx.lock.initLock()

  ctx.running.store(true)

  try:
    createThread(ctx.wakuThread, wakuThreadBody, ctx)
  except ValueError, ResourceExhaustedError:
    freeShared(ctx)
    return err("failed to create the Waku thread: " & getCurrentExceptionMsg())

  try:
    createThread(ctx.watchdogThread, watchdogThreadBody, ctx)
  except ValueError, ResourceExhaustedError:
    freeShared(ctx)
    return err("failed to create the watchdog thread: " & getCurrentExceptionMsg())

  return ok(ctx)

proc destroyWakuContext*(ctx: ptr WakuContext): Result[void, string] =
  ctx.running.store(false)

  let signaledOnTime = ctx.reqSignal.fireSync().valueOr:
    return err("error in destroyWakuContext: " & $error)
  if not signaledOnTime:
    return err("failed to signal reqSignal on time in destroyWakuContext")

  joinThread(ctx.wakuThread)
  joinThread(ctx.watchdogThread)
  ctx.lock.deinitLock()
  ?ctx.reqSignal.close()
  ?ctx.reqReceivedSignal.close()
  freeShared(ctx)

  return ok()
