import ../waku_relay, ../node/peer_manager, ../node/health_monitor/health_status

type AppCallbacks* = ref object
  relayHandler*: WakuRelayHandler
  topicHealthChangeHandler*: TopicHealthChangeHandler
  connectionChangeHandler*: ConnectionChangeHandler
  nodeHealthChangeHandler*: NodeHealthChangeHandler
