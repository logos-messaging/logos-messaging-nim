import options, std/[strutils, sequtils]
import chronicles, chronos, results, ffi
import
  ../../../../waku/waku_filter_v2/client,
  ../../../../waku/waku_core/message/message,
  ../../../../waku/factory/waku,
  ../../../../waku/waku_filter_v2/common,
  ../../../../waku/waku_core/subscription/push_handler,
  ../../../../waku/node/peer_manager/peer_manager,
  ../../../../waku/node/waku_node,
  ../../../../waku/node/kernel_api,
  ../../../../waku/waku_core/topics/pubsub_topic,
  ../../../../waku/waku_core/topics/content_topic

type FilterMsgType* = enum
  SUBSCRIBE
  UNSUBSCRIBE
  UNSUBSCRIBE_ALL

type FilterRequest* = object
  operation: FilterMsgType
  pubsubTopic: cstring
  contentTopics: cstring ## comma-separated list of content-topics
  filterPushEventCallback: FilterPushHandler ## handles incoming filter pushed msgs

proc createShared*(
    T: type FilterRequest,
    op: FilterMsgType,
    pubsubTopic: cstring = "",
    contentTopics: cstring = "",
    filterPushEventCallback: FilterPushHandler = nil,
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].pubsubTopic = pubsubTopic.alloc()
  ret[].contentTopics = contentTopics.alloc()
  ret[].filterPushEventCallback = filterPushEventCallback

  return ret

proc destroyShared(self: ptr FilterRequest) =
  deallocShared(self[].pubsubTopic)
  deallocShared(self[].contentTopics)
  deallocShared(self)

proc process*(
    self: ptr FilterRequest, waku: ptr Waku
): Future[Result[string, string]] {.async.} =
  defer:
    destroyShared(self)

  const FilterOpTimeout = 5.seconds
  if waku.node.wakuFilterClient.isNil():
    let errorMsg = "FilterRequest waku.node.wakuFilterClient is nil"
    error "fail filter process", error = errorMsg, op = $(self.operation)
    return err(errorMsg)

  case self.operation
  of SUBSCRIBE:
    waku.node.wakuFilterClient.registerPushHandler(self.filterPushEventCallback)

    let peer = waku.node.peerManager.selectPeer(WakuFilterSubscribeCodec).valueOr:
      let errorMsg =
        "could not find peer with WakuFilterSubscribeCodec when subscribing"
      error "fail filter process", error = errorMsg, op = $(self.operation)
      return err(errorMsg)

    let pubsubTopic = some(PubsubTopic($self[].pubsubTopic))
    let contentTopics = ($(self[].contentTopics)).split(",").mapIt(ContentTopic(it))

    let subFut = waku.node.filterSubscribe(pubsubTopic, contentTopics, peer)
    if not await subFut.withTimeout(FilterOpTimeout):
      let errorMsg = "filter subscription timed out"
      error "fail filter process", error = errorMsg, op = $(self.operation)
      return err(errorMsg)
  of UNSUBSCRIBE:
    let peer = waku.node.peerManager.selectPeer(WakuFilterSubscribeCodec).valueOr:
      let errorMsg =
        "could not find peer with WakuFilterSubscribeCodec when unsubscribing"
      error "fail filter process", error = errorMsg, op = $(self.operation)
      return err(errorMsg)

    let pubsubTopic = some(PubsubTopic($self[].pubsubTopic))
    let contentTopics = ($(self[].contentTopics)).split(",").mapIt(ContentTopic(it))

    let subFut = waku.node.filterUnsubscribe(pubsubTopic, contentTopics, peer)
    if not await subFut.withTimeout(FilterOpTimeout):
      let errorMsg = "filter un-subscription timed out"
      error "fail filter process", error = errorMsg, op = $(self.operation)
      return err(errorMsg)
  of UNSUBSCRIBE_ALL:
    let peer = waku.node.peerManager.selectPeer(WakuFilterSubscribeCodec).valueOr:
      let errorMsg =
        "could not find peer with WakuFilterSubscribeCodec when unsubscribing all"
      error "fail filter process", error = errorMsg, op = $(self.operation)
      return err(errorMsg)

    let unsubFut = waku.node.filterUnsubscribeAll(peer)

    if not await unsubFut.withTimeout(FilterOpTimeout):
      let errorMsg = "filter un-subscription all timed out"
      error "fail filter process", error = errorMsg, op = $(self.operation)
      return err(errorMsg)

  return ok("")
