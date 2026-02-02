import waku/common/broker/event_broker
import libp2p/switch

type
  WakuPeerEventKind* = enum
    Connected
    Disconnected
    Identified
    MetadataUpdated

EventBroker:
  type EventWakuPeer* = object
    peerId*: PeerId
    kind*: WakuPeerEventKind
