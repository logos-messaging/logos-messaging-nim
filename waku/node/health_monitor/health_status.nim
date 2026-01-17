import chronos, results, std/strutils

type HealthStatus* {.pure.} = enum
  INITIALIZING
  SYNCHRONIZING
  READY
  NOT_READY
  NOT_MOUNTED
  SHUTTING_DOWN

proc init*(t: typedesc[HealthStatus], strRep: string): Result[HealthStatus, string] =
  try:
    let status = parseEnum[HealthStatus](strRep)
    return ok(status)
  except ValueError:
    return err("Invalid HealthStatus string representation: " & strRep)

type NodeHealthStatus* {.pure.} = enum
  Disconnected = "Disconnected"
  PartiallyConnected = "PartiallyConnected"
  Connected = "Connected"

proc init*(t: typedesc[NodeHealthStatus], strRep: string): Result[NodeHealthStatus, string] =
  try:
    let status = parseEnum[NodeHealthStatus](strRep)
    return ok(status)
  except ValueError:
    return err("Invalid NodeHealthStatus string representation: " & strRep)

type NodeHealthChangeHandler* =
  proc(status: NodeHealthStatus): Future[void] {.gcsafe, raises: [Defect].}
