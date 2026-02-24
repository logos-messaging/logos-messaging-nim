{.push raises: [].}

import chronicles, waku/waku_core/topics

# Plan:
# - drive the continuous fulfillment and healing of edge peering and topic subscriptions
# - offload the edgeXXX stuff from WakuNode into this and finish it

type EdgeDriver* = ref object of RootObj # TODO: bg worker, ...

proc new*(T: typedesc[EdgeDriver]): T =
  return EdgeDriver()

proc start*(self: EdgeDriver) =
  # TODO
  debug "TODO: EdgeDriver: start bg worker"

proc stop*(self: EdgeDriver) =
  # TODO
  debug "TODO: EdgeDriver: stop bg worker"

proc subscribe*(self: EdgeDriver, shard: PubsubTopic, topic: ContentTopic) =
  # TODO: this is an event that can be used to drive an event-driven edge health checker
  debug "TODO: EdgeDriver: got subscribe notification", shard = shard, topic = topic

proc unsubscribe*(self: EdgeDriver, shard: PubsubTopic, topic: ContentTopic) =
  # TODO: this is an event that can be used to drive an event-driven edge health checker
  debug "TODO: EdgeDriver: got unsubscribe notification", shard = shard, topic = topic
