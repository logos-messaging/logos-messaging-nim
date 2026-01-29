import waku/common/broker/event_broker
import libp2p/switch

EventBroker:
  type EventWakuPeer* = object
    peerId*: PeerId
    kind*: PeerEventKind
