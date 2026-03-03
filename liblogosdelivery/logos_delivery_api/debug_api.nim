import std/[json, strutils]
import waku/factory/waku_state_info
import tools/confutils/[cli_args, config_option_meta]

proc logosdelivery_get_available_node_info_ids(
    ctx: ptr FFIContext[Waku], callback: FFICallBack, userData: pointer
) {.ffi.} =
  ## Returns the list of all available node info item ids that
  ## can be queried with `get_node_info_item`.
  requireInitializedNode(ctx, "GetNodeInfoIds"):
    return err(errMsg)

  return ok($ctx.myLib[].stateInfo.getAllPossibleInfoItemIds())

proc logosdelivery_get_node_info(
    ctx: ptr FFIContext[Waku],
    callback: FFICallBack,
    userData: pointer,
    nodeInfoId: cstring,
) {.ffi.} =
  ## Returns the content of the node info item with the given id if it exists.
  requireInitializedNode(ctx, "GetNodeInfoItem"):
    return err(errMsg)

  let infoItemIdEnum =
    try:
      parseEnum[NodeInfoId]($nodeInfoId)
    except ValueError:
      return err("Invalid node info id: " & $nodeInfoId)

  return ok(ctx.myLib[].stateInfo.getNodeInfoItem(infoItemIdEnum))

proc logosdelivery_get_available_configs(
    ctx: ptr FFIContext[Waku], callback: FFICallBack, userData: pointer
) {.ffi.} =
  ## Returns information about the accepted config items.
  requireInitializedNode(ctx, "GetAvailableConfigs"):
    return err(errMsg)

  let conf = defaultWakuNodeConf().valueOr:
    return err("Failed to get default logos-discovery configuration")

  let optionMetas: seq[ConfigOptionMeta] = extractConfigOptionMeta(WakuNodeConf)
  var configOptions: seq[string]
  var configOptionDetails = newJArray()
  var defaultConfig = newJObject()

  for confField, confValue in fieldPairs(conf):
    defaultConfig[confField] = %repr(confValue)

  for meta in optionMetas:
    configOptions.add(meta.fieldName)
    configOptionDetails.add(
      %*{
        "name": meta.fieldName,
        "type": meta.typeName,
        "cliName": meta.cliName,
        "desc": meta.desc,
        "defaultValue": meta.defaultValue,
        "command": meta.command,
      }
    )

  var jsonNode = newJObject()
  jsonNode["configOptions"] = %*configOptions
  jsonNode["configOptionDetails"] = configOptionDetails
  jsonNode["defaultConfig"] = defaultConfig
  let asString = pretty(jsonNode)
  return ok(asString)
