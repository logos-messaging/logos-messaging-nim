import std/[sets, tables, options, strutils], chronos, chronicles, results
import
  waku/[
    waku_core,
    waku_core/topics,
    waku_core/topics/sharding,
    waku_node,
    waku_relay,
    common/broker/broker_context,
    events/delivery_events,
    node/edge_driver,
  ]

type SubscriptionService* = ref object of RootObj
  node: WakuNode
  contentTopicSubs: Table[PubsubTopic, HashSet[ContentTopic]]
    ## Map of Shard to ContentTopic needed because e.g. WakuRelay is PubsubTopic only.
    ## A present key with an empty HashSet value means pubsubtopic already subscribed
    ## (via subscribeShard()) but there's no specific content topic interest yet.
  filterSubListener: OnFilterSubscribeEventListener
  filterUnsubListener: OnFilterUnsubscribeEventListener

proc new*(T: typedesc[SubscriptionService], node: WakuNode): T =
  SubscriptionService(
    node: node, contentTopicSubs: initTable[PubsubTopic, HashSet[ContentTopic]]()
  )

proc addContentTopicInterest(
    self: SubscriptionService, shard: PubsubTopic, topic: ContentTopic
) =
  try:
    if not self.contentTopicSubs.hasKey(shard):
      self.contentTopicSubs[shard] = initHashSet[ContentTopic]()

    if not self.contentTopicSubs[shard].contains(topic):
      self.contentTopicSubs[shard].incl(topic)

      # Always notify EdgeDriver if filter is mounted
      if not isNil(self.node.wakuFilterClient):
        self.node.edgeDriver.subscribe(shard, topic)
  except KeyError:
    discard

proc removeContentTopicInterest(
    self: SubscriptionService, shard: PubsubTopic, topic: ContentTopic
) =
  try:
    if self.contentTopicSubs.hasKey(shard) and
        self.contentTopicSubs[shard].contains(topic):
      self.contentTopicSubs[shard].excl(topic)

      # Only delete the shard tracking if we are not running a Relay.
      # If Relay is mounted, we keep the empty HashSet to signal the relay shard sub.
      if self.contentTopicSubs[shard].len == 0 and isNil(self.node.wakuRelay):
        self.contentTopicSubs.del(shard)

      if not isNil(self.node.wakuFilterClient):
        self.node.edgeDriver.unsubscribe(shard, topic)
  except KeyError:
    discard

proc startProvidersAndListeners*(self: SubscriptionService): Result[void, string] =
  self.filterSubListener = OnFilterSubscribeEvent.listen(
    self.node.brokerCtx,
    proc(event: OnFilterSubscribeEvent) {.async: (raises: []), gcsafe.} =
      for cTopic in event.contentTopics:
        self.addContentTopicInterest(event.pubsubTopic, cTopic),
  ).valueOr:
    return
      err("SubscriptionService failed to listen to OnFilterSubscribeEvent: " & error)

  self.filterUnsubListener = OnFilterUnsubscribeEvent.listen(
    self.node.brokerCtx,
    proc(event: OnFilterUnsubscribeEvent) {.async: (raises: []), gcsafe.} =
      for cTopic in event.contentTopics:
        self.removeContentTopicInterest(event.pubsubTopic, cTopic),
  ).valueOr:
    return
      err("SubscriptionService failed to listen to OnFilterUnsubscribeEvent: " & error)

  return ok()

proc stopProvidersAndListeners*(self: SubscriptionService) =
  OnFilterSubscribeEvent.dropListener(self.node.brokerCtx, self.filterSubListener)
  OnFilterUnsubscribeEvent.dropListener(self.node.brokerCtx, self.filterUnsubListener)

proc start*(self: SubscriptionService) =
  # TODO: re-enable for MAPI edge support.
  #self.startProvidersAndListeners().isOkOr:
  #  error "Fatal error in SubscriptionService.startProvidersAndListeners(): ",
  #    error = error
  #  raise newException(ValueError, "SubscriptionService.start() failed: " & error)
  discard

proc stop*(self: SubscriptionService) =
  # TODO: re-enable for MAPI edge support.
  #self.stopProvidersAndListeners()
  discard

proc getActiveSubscriptions*(
    self: SubscriptionService
): seq[tuple[pubsubTopic: string, contentTopics: seq[ContentTopic]]] =
  var activeSubs: seq[tuple[pubsubTopic: string, contentTopics: seq[ContentTopic]]] =
    @[]

  for pubsub, cTopicSet in self.contentTopicSubs.pairs:
    if cTopicSet.len > 0:
      var cTopicSeq = newSeqOfCap[ContentTopic](cTopicSet.len)
      for t in cTopicSet:
        cTopicSeq.add(t)
      activeSubs.add((pubsub, cTopicSeq))

  return activeSubs

proc getShardForContentTopic(
    self: SubscriptionService, topic: ContentTopic
): Result[PubsubTopic, string] =
  if self.node.wakuAutoSharding.isSome():
    let shardObj = ?self.node.wakuAutoSharding.get().getShard(topic)
    return ok($shardObj)

  return err("SubscriptionService requires AutoSharding")

proc isSubscribed*(
    self: SubscriptionService, topic: ContentTopic
): Result[bool, string] =
  let shard = ?self.getShardForContentTopic(topic)
  return ok(
    self.contentTopicSubs.hasKey(shard) and self.contentTopicSubs[shard].contains(topic)
  )

proc isSubscribed*(
    self: SubscriptionService, shard: PubsubTopic, contentTopic: ContentTopic
): bool {.raises: [].} =
  try:
    return
      self.contentTopicSubs.hasKey(shard) and
      self.contentTopicSubs[shard].contains(contentTopic)
  except KeyError:
    discard

proc subscribeShard*(
    self: SubscriptionService, shards: seq[PubsubTopic]
): Result[void, string] =
  if isNil(self.node.wakuRelay):
    return err("subscribeShard requires a Relay")

  var errors: seq[string] = @[]

  for shard in shards:
    if not self.contentTopicSubs.hasKey(shard):
      self.node.subscribe((kind: PubsubSub, topic: shard), nil).isOkOr:
        errors.add("shard " & shard & ": " & error)
        continue

      self.contentTopicSubs[shard] = initHashSet[ContentTopic]()

  if errors.len > 0:
    return err("subscribeShard errors: " & errors.join("; "))

  return ok()

proc unsubscribeShard*(
    self: SubscriptionService, shards: seq[PubsubTopic]
): Result[void, string] =
  if isNil(self.node.wakuRelay):
    return err("unsubscribeShard requires a Relay")

  var errors: seq[string] = @[]

  for shard in shards:
    if self.contentTopicSubs.hasKey(shard):
      self.node.unsubscribe((kind: PubsubUnsub, topic: shard)).isOkOr:
        errors.add("shard " & shard & ": " & error)

      self.contentTopicSubs.del(shard)

  if errors.len > 0:
    return err("unsubscribeShard errors: " & errors.join("; "))

  return ok()

proc subscribe*(self: SubscriptionService, topic: ContentTopic): Result[void, string] =
  if isNil(self.node.wakuRelay) and isNil(self.node.wakuFilterClient):
    return err("SubscriptionService requires either Relay or Filter Client.")

  let shard = ?self.getShardForContentTopic(topic)

  if not isNil(self.node.wakuRelay) and not self.contentTopicSubs.hasKey(shard):
    ?self.subscribeShard(@[shard])

  self.addContentTopicInterest(shard, topic)

  return ok()

proc unsubscribe*(
    self: SubscriptionService, topic: ContentTopic
): Result[void, string] =
  if isNil(self.node.wakuRelay) and isNil(self.node.wakuFilterClient):
    return err("SubscriptionService requires either Relay or Filter Client.")

  let shard = ?self.getShardForContentTopic(topic)

  if self.isSubscribed(shard, topic):
    self.removeContentTopicInterest(shard, topic)

  return ok()
