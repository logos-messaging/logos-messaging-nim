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
  ]

type SubscriptionService* = ref object of RootObj
  node: WakuNode
  contentTopicSubs: Table[PubsubTopic, HashSet[ContentTopic]]
    ## Map of Shard to ContentTopic needed because e.g. WakuRelay is PubsubTopic only.
    ## A present key with an empty HashSet value means pubsubtopic already subscribed
    ## (via subscribePubsubTopics()) but there's no specific content topic interest yet.

proc new*(T: typedesc[SubscriptionService], node: WakuNode): T =
  SubscriptionService(
    node: node, contentTopicSubs: initTable[PubsubTopic, HashSet[ContentTopic]]()
  )

proc addContentTopicInterest(
    self: SubscriptionService, shard: PubsubTopic, topic: ContentTopic
): Result[void, string] =
  if not self.contentTopicSubs.hasKey(shard):
    self.contentTopicSubs[shard] = initHashSet[ContentTopic]()

  self.contentTopicSubs.withValue(shard, cTopics):
    if not cTopics[].contains(topic):
      cTopics[].incl(topic)

      # TODO: Call a "subscribe(shard, topic)" on filter client here,
      #       so the filter client can know that subscriptions changed.

  return ok()

proc removeContentTopicInterest(
    self: SubscriptionService, shard: PubsubTopic, topic: ContentTopic
): Result[void, string] =
  self.contentTopicSubs.withValue(shard, cTopics):
    if cTopics[].contains(topic):
      cTopics[].excl(topic)

      if cTopics[].len == 0 and isNil(self.node.wakuRelay):
        self.contentTopicSubs.del(shard) # We're done with cTopics here

      # TODO: Call a "unsubscribe(shard, topic)" on filter client here,
      #       so the filter client can know that subscriptions changed.

  return ok()

proc subscribePubsubTopics*(
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

proc startSubscriptionService*(self: SubscriptionService) =
  if not isNil(self.node.wakuRelay):
    if self.node.wakuAutoSharding.isSome():
      # Subscribe relay to all shards in autosharding.
      let autoSharding = self.node.wakuAutoSharding.get()
      let clusterId = autoSharding.clusterId
      let numShards = autoSharding.shardCountGenZero

      if numShards > 0:
        var clusterPubsubTopics = newSeqOfCap[PubsubTopic](numShards)

        for i in 0 ..< numShards:
          let shardObj = RelayShard(clusterId: clusterId, shardId: uint16(i))
          clusterPubsubTopics.add(PubsubTopic($shardObj))

        self.subscribePubsubTopics(clusterPubsubTopics).isOkOr:
          error "Failed to auto-subscribe Relay to cluster shards: ", error = error
    else:
      # NOTE: We can't fallback to configured shards when no autosharding here since
      #       we don't currently have access to Waku.conf here. However, we don't support
      #       manual/static sharding at the MAPI level anyway so wiring that up now is not needed.
      #       When we no longer auto-subscribe to all shards in Core boot, we will probably
      #       scan the shard config due to fleet nodes; then shard conf will have to be reachable here.
      #       For non-fleet, interactive Core nodes (e.g. Desktop apps) this can't matter
      #       as much since shard subscriptions originate from subscription to content topics, but
      #       I guess even in that case subbing to some conf shards may make sense for some apps.
      info "SubscriptionService has no AutoSharding for Relay, won't subscribe to shards by default."

  discard

proc stopSubscriptionService*(self: SubscriptionService) {.async.} =
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

proc subscribe*(self: SubscriptionService, topic: ContentTopic): Result[void, string] =
  if isNil(self.node.wakuRelay) and isNil(self.node.wakuFilterClient):
    return err("SubscriptionService requires either Relay or Filter Client.")

  let shard = ?self.getShardForContentTopic(topic)

  if not isNil(self.node.wakuRelay) and not self.contentTopicSubs.hasKey(shard):
    ?self.subscribePubsubTopics(@[shard])

  ?self.addContentTopicInterest(shard, topic)

  return ok()

proc unsubscribe*(
    self: SubscriptionService, topic: ContentTopic
): Result[void, string] =
  if isNil(self.node.wakuRelay) and isNil(self.node.wakuFilterClient):
    return err("SubscriptionService requires either Relay or Filter Client.")

  let shard = ?self.getShardForContentTopic(topic)

  if self.isSubscribed(shard, topic):
    ?self.removeContentTopicInterest(shard, topic)

  return ok()
