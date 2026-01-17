{.push raises: [].}

import system, std/json
import ./json_base_event
import ../../waku/node/health_monitor/health_status

type JsonNodeHealthChangeEvent* = ref object of JsonEvent
  status*: NodeHealthStatus

proc new*(
    T: type JsonNodeHealthChangeEvent, status: NodeHealthStatus
): T =
  return JsonNodeHealthChangeEvent(
    eventType: "node_health_change",
    status: status
  )

method `$`*(event: JsonNodeHealthChangeEvent): string =
  $(%*event)
