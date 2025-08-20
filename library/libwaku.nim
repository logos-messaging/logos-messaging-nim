{.pragma: exported, exportc, cdecl, raises: [].}
{.pragma: callback, cdecl, raises: [], gcsafe.}
{.passc: "-fPIC".}

when defined(linux):
  {.passl: "-Wl,-soname,libwaku.so".}

import std/[json, atomics, strformat, options, atomics, macros]
import chronicles, chronos, chronos/threadsync, ffi
import
  waku/factory/waku,
  waku/common/base64,
  waku/waku_core/message/message,
  waku/node/waku_node,
  waku/node/peer_manager,
  waku/waku_core/topics/pubsub_topic,
  waku/waku_core/subscription/push_handler,
  waku/waku_relay,
  ./events/json_message_event,
  ./waku_thread_requests/requests/node_lifecycle_request,
  ./waku_thread_requests/requests/create_node_request,
  ./waku_thread_requests/requests/peer_manager_request,
  ./waku_thread_requests/requests/protocols/relay_request,
  ./waku_thread_requests/requests/protocols/store_request,
  ./waku_thread_requests/requests/protocols/lightpush_request,
  ./waku_thread_requests/requests/protocols/filter_request,
  ./waku_thread_requests/requests/debug_node_request,
  ./waku_thread_requests/requests/discovery_request,
  ./waku_thread_requests/requests/ping_request,
  ./waku_thread_requests/waku_thread_request,
  ../waku/factory/app_callbacks

################################################################################
### Wrapper around the waku node
################################################################################

################################################################################
### Not-exported components

expandMacros:
  declareLibrary("waku")

template checkLibwakuParams*(
    ctx: ptr FFIContext, callback: FFICallBack, userData: pointer
) =
  if not isNil(ctx):
    ctx[].userData = userData

  if isNil(callback):
    return RET_MISSING_CALLBACK

# proc handleRequest(ctx: ptr FFIContext, ffiRequest: ptr FFIThreadRequest): cint =
#   ffi_context.sendRequestToFFIThread(ctx, ffiRequest).isOkOr:
#     let msg = "libwaku error: " & $error
#     callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
#     return RET_ERR

#   return RET_OK

### End of not-exported components
################################################################################

################################################################################
### Exported procs

proc waku_new(
    callback: FFICallback, userData: pointer, configJson: cstring
): pointer {.dynlib, exportc, cdecl.} =
  initializeLibrary()

  ## Creates a new instance of the WakuNode.
  if isNil(callback):
    echo "error: missing callback in waku_new"
    return nil

  ## Create the Waku thread that will keep waiting for req from the main thread.
  var ctx = ffi_context.createFFIContext(Waku).valueOr:
    let msg = "Error in createWakuContext: " & $error
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return nil

  ctx.userData = userData

  let appCallbacks = AppCallbacks(
    # relayHandler: onReceivedMessage(ctx),
    # topicHealthChangeHandler: onTopicHealthChange(ctx),
    # connectionChangeHandler: onConnectionChange(ctx),
  )

  ffi_context.sendRequestToFFIThread(
    ctx, CreateNodeRequest.ffiNewReq(callback, userData, configJson, appCallbacks)
  ).isOkOr:
    let msg = "error in sendRequestToFFIThread: " & $error
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return nil

  return ctx

# proc waku_destroy(
#     ctx: ptr FFIContext, callback: FFICallBack, userData: pointer
# ): cint {.dynlib, exportc.} =
#   initializeLibrary()
#   checkLibwakuParams(ctx, callback, userData)

#   ffi_context.destroyWakuContext(ctx).isOkOr:
#     let msg = "libwaku error: " & $error
#     callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
#     return RET_ERR

#   ## always need to invoke the callback although we don't retrieve value to the caller
#   callback(RET_OK, nil, 0, userData)

#   return RET_OK

# proc waku_version(
#     ctx: ptr FFIContext, callback: FFICallBack, userData: pointer
# ): cint {.dynlib, exportc.} =
#   initializeLibrary()
#   checkLibwakuParams(ctx, callback, userData)
#   callback(
#     RET_OK,
#     cast[ptr cchar](WakuNodeVersionString),
#     cast[csize_t](len(WakuNodeVersionString)),
#     userData,
#   )

#   return RET_OK

# proc waku_set_event_callback(
#     ctx: ptr FFIContext, callback: FFICallBack, userData: pointer
# ) {.dynlib, exportc.} =
#   initializeLibrary()
#   ctx[].eventCallback = cast[pointer](callback)
#   ctx[].eventUserData = userData

# proc waku_content_topic(
#     ctx: ptr FFIContext,
#     appName: cstring,
#     appVersion: cuint,
#     contentTopicName: cstring,
#     encoding: cstring,
#     callback: FFICallBack,
#     userData: pointer,
# ): cint {.dynlib, exportc.} =
#   # https://rfc.vac.dev/spec/36/#extern-char-waku_content_topicchar-applicationname-unsigned-int-applicationversion-char-contenttopicname-char-encoding

#   initializeLibrary()
#   checkLibwakuParams(ctx, callback, userData)

#   let contentTopic = fmt"/{$appName}/{$appVersion}/{$contentTopicName}/{$encoding}"
#   callback(
#     RET_OK, unsafeAddr contentTopic[0], cast[csize_t](len(contentTopic)), userData
#   )

#   return RET_OK

# proc waku_pubsub_topic(
#     ctx: ptr FFIContext, topicName: cstring, callback: FFICallBack, userData: pointer
# ): cint {.dynlib, exportc, cdecl.} =
#   # https://rfc.vac.dev/spec/36/#extern-char-waku_pubsub_topicchar-name-char-encoding

#   initializeLibrary()
#   checkLibwakuParams(ctx, callback, userData)

#   let outPubsubTopic = fmt"/waku/2/{$topicName}"
#   callback(
#     RET_OK, unsafeAddr outPubsubTopic[0], cast[csize_t](len(outPubsubTopic)), userData
#   )

#   return RET_OK

# proc waku_default_pubsub_topic(
#     ctx: ptr FFIContext, callback: FFICallBack, userData: pointer
# ): cint {.dynlib, exportc.} =
#   # https://rfc.vac.dev/spec/36/#extern-char-waku_default_pubsub_topic

#   initializeLibrary()
#   checkLibwakuParams(ctx, callback, userData)

#   callback(
#     RET_OK,
#     cast[ptr cchar](DefaultPubsubTopic),
#     cast[csize_t](len(DefaultPubsubTopic)),
#     userData,
#   )

#   return RET_OK

# proc waku_relay_publish(
#     ctx: ptr FFIContext,
#     pubSubTopic: cstring,
#     jsonWakuMessage: cstring,
#     timeoutMs: cuint,
#     callback: FFICallBack,
#     userData: pointer,
# ): cint {.dynlib, exportc, cdecl.} =
#   # https://rfc.vac.dev/spec/36/#extern-char-waku_relay_publishchar-messagejson-char-pubsubtopic-int-timeoutms

#   initializeLibrary()
#   checkLibwakuParams(ctx, callback, userData)

#   var jsonMessage: JsonMessage
#   try:
#     let jsonContent = parseJson($jsonWakuMessage)
#     jsonMessage = JsonMessage.fromJsonNode(jsonContent).valueOr:
#       raise newException(JsonParsingError, $error)
#   except JsonParsingError:
#     let msg = fmt"Error parsing json message: {getCurrentExceptionMsg()}"
#     callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
#     return RET_ERR

#   let wakuMessage = jsonMessage.toWakuMessage().valueOr:
#     let msg = "Problem building the WakuMessage: " & $error
#     callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
#     return RET_ERR

#   handleRequest(
#     ctx,
#     RequestType.RELAY,
#     RelayRequest.createShared(RelayMsgType.PUBLISH, pubSubTopic, nil, wakuMessage),
#     callback,
#     userData,
#   )

# proc waku_start(
#     ctx: ptr FFIContext, callback: FFICallBack, userData: pointer
# ): cint {.dynlib, exportc.} =
#   initializeLibrary()
#   checkLibwakuParams(ctx, callback, userData)
#   handleRequest(
#     ctx,
#     RequestType.LIFECYCLE,
#     NodeLifecycleRequest.createShared(NodeLifecycleMsgType.START_NODE),
#     callback,
#     userData,
#   )

# proc waku_stop(
#     ctx: ptr FFIContext, callback: FFICallBack, userData: pointer
# ): cint {.dynlib, exportc.} =
#   initializeLibrary()
#   checkLibwakuParams(ctx, callback, userData)
#   handleRequest(
#     ctx,
#     RequestType.LIFECYCLE,
#     NodeLifecycleRequest.createShared(NodeLifecycleMsgType.STOP_NODE),
#     callback,
#     userData,
#   )

# proc waku_relay_subscribe(
#     ctx: ptr FFIContext, pubSubTopic: cstring, callback: FFICallBack, userData: pointer
# ): cint {.dynlib, exportc.} =
#   initializeLibrary()
#   checkLibwakuParams(ctx, callback, userData)

#   var cb = onReceivedMessage(ctx)

#   handleRequest(
#     ctx,
#     RequestType.RELAY,
#     RelayRequest.createShared(RelayMsgType.SUBSCRIBE, pubSubTopic, WakuRelayHandler(cb)),
#     callback,
#     userData,
#   )

# proc waku_relay_add_protected_shard(
#     ctx: ptr FFIContext,
#     clusterId: cint,
#     shardId: cint,
#     publicKey: cstring,
#     callback: FFICallBack,
#     userData: pointer,
# ): cint {.dynlib, exportc, cdecl.} =
#   initializeLibrary()
#   checkLibwakuParams(ctx, callback, userData)

#   handleRequest(
#     ctx,
#     RequestType.RELAY,
#     RelayRequest.createShared(
#       RelayMsgType.ADD_PROTECTED_SHARD,
#       clusterId = clusterId,
#       shardId = shardId,
#       publicKey = publicKey,
#     ),
#     callback,
#     userData,
#   )

# proc waku_relay_unsubscribe(
#     ctx: ptr FFIContext, pubSubTopic: cstring, callback: FFICallBack, userData: pointer
# ): cint {.dynlib, exportc.} =
#   initializeLibrary()
#   checkLibwakuParams(ctx, callback, userData)

#   handleRequest(
#     ctx,
#     RequestType.RELAY,
#     RelayRequest.createShared(
#       RelayMsgType.UNSUBSCRIBE, pubSubTopic, WakuRelayHandler(onReceivedMessage(ctx))
#     ),
#     callback,
#     userData,
#   )

# proc waku_relay_get_num_connected_peers(
#     ctx: ptr FFIContext, pubSubTopic: cstring, callback: FFICallBack, userData: pointer
# ): cint {.dynlib, exportc.} =
#   initializeLibrary()
#   checkLibwakuParams(ctx, callback, userData)

#   handleRequest(
#     ctx,
#     RequestType.RELAY,
#     RelayRequest.createShared(RelayMsgType.NUM_CONNECTED_PEERS, pubSubTopic),
#     callback,
#     userData,
#   )

# proc waku_relay_get_connected_peers(
#     ctx: ptr FFIContext, pubSubTopic: cstring, callback: FFICallBack, userData: pointer
# ): cint {.dynlib, exportc.} =
#   initializeLibrary()
#   checkLibwakuParams(ctx, callback, userData)

#   handleRequest(
#     ctx,
#     RequestType.RELAY,
#     RelayRequest.createShared(RelayMsgType.LIST_CONNECTED_PEERS, pubSubTopic),
#     callback,
#     userData,
#   )

# proc waku_relay_get_num_peers_in_mesh(
#     ctx: ptr FFIContext, pubSubTopic: cstring, callback: FFICallBack, userData: pointer
# ): cint {.dynlib, exportc.} =
#   initializeLibrary()
#   checkLibwakuParams(ctx, callback, userData)

#   handleRequest(
#     ctx,
#     RequestType.RELAY,
#     RelayRequest.createShared(RelayMsgType.NUM_MESH_PEERS, pubSubTopic),
#     callback,
#     userData,
#   )

# proc waku_relay_get_peers_in_mesh(
#     ctx: ptr FFIContext, pubSubTopic: cstring, callback: FFICallBack, userData: pointer
# ): cint {.dynlib, exportc.} =
#   initializeLibrary()
#   checkLibwakuParams(ctx, callback, userData)

#   handleRequest(
#     ctx,
#     RequestType.RELAY,
#     RelayRequest.createShared(RelayMsgType.LIST_MESH_PEERS, pubSubTopic),
#     callback,
#     userData,
#   )

# proc waku_filter_subscribe(
#     ctx: ptr FFIContext,
#     pubSubTopic: cstring,
#     contentTopics: cstring,
#     callback: FFICallBack,
#     userData: pointer,
# ): cint {.dynlib, exportc.} =
#   initializeLibrary()
#   checkLibwakuParams(ctx, callback, userData)

#   handleRequest(
#     ctx,
#     RequestType.FILTER,
#     FilterRequest.createShared(
#       FilterMsgType.SUBSCRIBE,
#       pubSubTopic,
#       contentTopics,
#       FilterPushHandler(onReceivedMessage(ctx)),
#     ),
#     callback,
#     userData,
#   )

# proc waku_filter_unsubscribe(
#     ctx: ptr FFIContext,
#     pubSubTopic: cstring,
#     contentTopics: cstring,
#     callback: FFICallBack,
#     userData: pointer,
# ): cint {.dynlib, exportc.} =
#   initializeLibrary()
#   checkLibwakuParams(ctx, callback, userData)

#   handleRequest(
#     ctx,
#     RequestType.FILTER,
#     FilterRequest.createShared(FilterMsgType.UNSUBSCRIBE, pubSubTopic, contentTopics),
#     callback,
#     userData,
#   )

# proc waku_filter_unsubscribe_all(
#     ctx: ptr FFIContext, callback: FFICallBack, userData: pointer
# ): cint {.dynlib, exportc.} =
#   initializeLibrary()
#   checkLibwakuParams(ctx, callback, userData)

#   handleRequest(
#     ctx,
#     RequestType.FILTER,
#     FilterRequest.createShared(FilterMsgType.UNSUBSCRIBE_ALL),
#     callback,
#     userData,
#   )

# proc waku_lightpush_publish(
#     ctx: ptr FFIContext,
#     pubSubTopic: cstring,
#     jsonWakuMessage: cstring,
#     callback: FFICallBack,
#     userData: pointer,
# ): cint {.dynlib, exportc, cdecl.} =
#   initializeLibrary()
#   checkLibwakuParams(ctx, callback, userData)

#   var jsonMessage: JsonMessage
#   try:
#     let jsonContent = parseJson($jsonWakuMessage)
#     jsonMessage = JsonMessage.fromJsonNode(jsonContent).valueOr:
#       raise newException(JsonParsingError, $error)
#   except JsonParsingError:
#     let msg = fmt"Error parsing json message: {getCurrentExceptionMsg()}"
#     callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
#     return RET_ERR

#   let wakuMessage = jsonMessage.toWakuMessage().valueOr:
#     let msg = "Problem building the WakuMessage: " & $error
#     callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
#     return RET_ERR

#   handleRequest(
#     ctx,
#     RequestType.LIGHTPUSH,
#     LightpushRequest.createShared(LightpushMsgType.PUBLISH, pubSubTopic, wakuMessage),
#     callback,
#     userData,
#   )

# proc waku_connect(
#     ctx: ptr FFIContext,
#     peerMultiAddr: cstring,
#     timeoutMs: cuint,
#     callback: FFICallBack,
#     userData: pointer,
# ): cint {.dynlib, exportc.} =
#   initializeLibrary()
#   checkLibwakuParams(ctx, callback, userData)

#   handleRequest(
#     ctx,
#     RequestType.PEER_MANAGER,
#     PeerManagementRequest.createShared(
#       PeerManagementMsgType.CONNECT_TO, $peerMultiAddr, chronos.milliseconds(timeoutMs)
#     ),
#     callback,
#     userData,
#   )

# proc waku_disconnect_peer_by_id(
#     ctx: ptr FFIContext, peerId: cstring, callback: FFICallBack, userData: pointer
# ): cint {.dynlib, exportc.} =
#   initializeLibrary()
#   checkLibwakuParams(ctx, callback, userData)

#   handleRequest(
#     ctx,
#     RequestType.PEER_MANAGER,
#     PeerManagementRequest.createShared(
#       op = PeerManagementMsgType.DISCONNECT_PEER_BY_ID, peerId = $peerId
#     ),
#     callback,
#     userData,
#   )

# proc waku_disconnect_all_peers(
#     ctx: ptr FFIContext, callback: FFICallBack, userData: pointer
# ): cint {.dynlib, exportc.} =
#   initializeLibrary()
#   checkLibwakuParams(ctx, callback, userData)

#   handleRequest(
#     ctx,
#     RequestType.PEER_MANAGER,
#     PeerManagementRequest.createShared(op = PeerManagementMsgType.DISCONNECT_ALL_PEERS),
#     callback,
#     userData,
#   )

# proc waku_dial_peer(
#     ctx: ptr FFIContext,
#     peerMultiAddr: cstring,
#     protocol: cstring,
#     timeoutMs: cuint,
#     callback: FFICallBack,
#     userData: pointer,
# ): cint {.dynlib, exportc.} =
#   initializeLibrary()
#   checkLibwakuParams(ctx, callback, userData)

#   handleRequest(
#     ctx,
#     RequestType.PEER_MANAGER,
#     PeerManagementRequest.createShared(
#       op = PeerManagementMsgType.DIAL_PEER,
#       peerMultiAddr = $peerMultiAddr,
#       protocol = $protocol,
#     ),
#     callback,
#     userData,
#   )

# proc waku_dial_peer_by_id(
#     ctx: ptr FFIContext,
#     peerId: cstring,
#     protocol: cstring,
#     timeoutMs: cuint,
#     callback: FFICallBack,
#     userData: pointer,
# ): cint {.dynlib, exportc.} =
#   initializeLibrary()
#   checkLibwakuParams(ctx, callback, userData)

#   handleRequest(
#     ctx,
#     RequestType.PEER_MANAGER,
#     PeerManagementRequest.createShared(
#       op = PeerManagementMsgType.DIAL_PEER_BY_ID, peerId = $peerId, protocol = $protocol
#     ),
#     callback,
#     userData,
#   )

# proc waku_get_peerids_from_peerstore(
#     ctx: ptr FFIContext, callback: FFICallBack, userData: pointer
# ): cint {.dynlib, exportc.} =
#   initializeLibrary()
#   checkLibwakuParams(ctx, callback, userData)

#   handleRequest(
#     ctx,
#     RequestType.PEER_MANAGER,
#     PeerManagementRequest.createShared(PeerManagementMsgType.GET_ALL_PEER_IDS),
#     callback,
#     userData,
#   )

# proc waku_get_connected_peers_info(
#     ctx: ptr FFIContext, callback: FFICallBack, userData: pointer
# ): cint {.dynlib, exportc.} =
#   initializeLibrary()
#   checkLibwakuParams(ctx, callback, userData)

#   handleRequest(
#     ctx,
#     RequestType.PEER_MANAGER,
#     PeerManagementRequest.createShared(PeerManagementMsgType.GET_CONNECTED_PEERS_INFO),
#     callback,
#     userData,
#   )

# proc waku_get_connected_peers(
#     ctx: ptr FFIContext, callback: FFICallBack, userData: pointer
# ): cint {.dynlib, exportc.} =
#   initializeLibrary()
#   checkLibwakuParams(ctx, callback, userData)

#   handleRequest(
#     ctx,
#     RequestType.PEER_MANAGER,
#     PeerManagementRequest.createShared(PeerManagementMsgType.GET_CONNECTED_PEERS),
#     callback,
#     userData,
#   )

# proc waku_get_peerids_by_protocol(
#     ctx: ptr FFIContext, protocol: cstring, callback: FFICallBack, userData: pointer
# ): cint {.dynlib, exportc.} =
#   initializeLibrary()
#   checkLibwakuParams(ctx, callback, userData)

#   handleRequest(
#     ctx,
#     RequestType.PEER_MANAGER,
#     PeerManagementRequest.createShared(
#       op = PeerManagementMsgType.GET_PEER_IDS_BY_PROTOCOL, protocol = $protocol
#     ),
#     callback,
#     userData,
#   )

# proc waku_store_query(
#     ctx: ptr FFIContext,
#     jsonQuery: cstring,
#     peerAddr: cstring,
#     timeoutMs: cint,
#     callback: FFICallBack,
#     userData: pointer,
# ): cint {.dynlib, exportc.} =
#   initializeLibrary()
#   checkLibwakuParams(ctx, callback, userData)

#   handleRequest(
#     ctx,
#     RequestType.STORE,
#     StoreRequest.createShared(StoreReqType.REMOTE_QUERY, jsonQuery, peerAddr, timeoutMs),
#     callback,
#     userData,
#   )

# proc waku_listen_addresses(
#     ctx: ptr FFIContext, callback: FFICallBack, userData: pointer
# ): cint {.dynlib, exportc.} =
#   initializeLibrary()
#   checkLibwakuParams(ctx, callback, userData)

#   handleRequest(
#     ctx,
#     RequestType.DEBUG,
#     DebugNodeRequest.createShared(DebugNodeMsgType.RETRIEVE_LISTENING_ADDRESSES),
#     callback,
#     userData,
#   )

# proc waku_dns_discovery(
#     ctx: ptr FFIContext,
#     entTreeUrl: cstring,
#     nameDnsServer: cstring,
#     timeoutMs: cint,
#     callback: FFICallBack,
#     userData: pointer,
# ): cint {.dynlib, exportc.} =
#   initializeLibrary()
#   checkLibwakuParams(ctx, callback, userData)

#   handleRequest(
#     ctx,
#     RequestType.DISCOVERY,
#     DiscoveryRequest.createRetrieveBootstrapNodesRequest(
#       DiscoveryMsgType.GET_BOOTSTRAP_NODES, entTreeUrl, nameDnsServer, timeoutMs
#     ),
#     callback,
#     userData,
#   )

# proc waku_discv5_update_bootnodes(
#     ctx: ptr FFIContext, bootnodes: cstring, callback: FFICallBack, userData: pointer
# ): cint {.dynlib, exportc.} =
#   ## Updates the bootnode list used for discovering new peers via DiscoveryV5
#   ## bootnodes - JSON array containing the bootnode ENRs i.e. `["enr:...", "enr:..."]`
#   initializeLibrary()
#   checkLibwakuParams(ctx, callback, userData)

#   handleRequest(
#     ctx,
#     RequestType.DISCOVERY,
#     DiscoveryRequest.createUpdateBootstrapNodesRequest(
#       DiscoveryMsgType.UPDATE_DISCV5_BOOTSTRAP_NODES, bootnodes
#     ),
#     callback,
#     userData,
#   )

# proc waku_get_my_enr(
#     ctx: ptr FFIContext, callback: FFICallBack, userData: pointer
# ): cint {.dynlib, exportc.} =
#   initializeLibrary()
#   checkLibwakuParams(ctx, callback, userData)

#   handleRequest(
#     ctx,
#     RequestType.DEBUG,
#     DebugNodeRequest.createShared(DebugNodeMsgType.RETRIEVE_MY_ENR),
#     callback,
#     userData,
#   )

# proc waku_get_my_peerid(
#     ctx: ptr FFIContext, callback: FFICallBack, userData: pointer
# ): cint {.dynlib, exportc.} =
#   initializeLibrary()
#   checkLibwakuParams(ctx, callback, userData)

#   handleRequest(
#     ctx,
#     RequestType.DEBUG,
#     DebugNodeRequest.createShared(DebugNodeMsgType.RETRIEVE_MY_PEER_ID),
#     callback,
#     userData,
#   )

# proc waku_get_metrics(
#     ctx: ptr FFIContext, callback: FFICallBack, userData: pointer
# ): cint {.dynlib, exportc.} =
#   initializeLibrary()
#   checkLibwakuParams(ctx, callback, userData)

#   handleRequest(
#     ctx,
#     RequestType.DEBUG,
#     DebugNodeRequest.createShared(DebugNodeMsgType.RETRIEVE_METRICS),
#     callback,
#     userData,
#   )

# proc waku_start_discv5(
#     ctx: ptr FFIContext, callback: FFICallBack, userData: pointer
# ): cint {.dynlib, exportc.} =
#   initializeLibrary()
#   checkLibwakuParams(ctx, callback, userData)

#   handleRequest(
#     ctx,
#     RequestType.DISCOVERY,
#     DiscoveryRequest.createDiscV5StartRequest(),
#     callback,
#     userData,
#   )

# proc waku_stop_discv5(
#     ctx: ptr FFIContext, callback: FFICallBack, userData: pointer
# ): cint {.dynlib, exportc.} =
#   initializeLibrary()
#   checkLibwakuParams(ctx, callback, userData)

#   handleRequest(
#     ctx,
#     RequestType.DISCOVERY,
#     DiscoveryRequest.createDiscV5StopRequest(),
#     callback,
#     userData,
#   )

# proc waku_peer_exchange_request(
#     ctx: ptr FFIContext, numPeers: uint64, callback: FFICallBack, userData: pointer
# ): cint {.dynlib, exportc.} =
#   initializeLibrary()
#   checkLibwakuParams(ctx, callback, userData)

#   handleRequest(
#     ctx,
#     RequestType.DISCOVERY,
#     DiscoveryRequest.createPeerExchangeRequest(numPeers),
#     callback,
#     userData,
#   )

# proc waku_ping_peer(
#     ctx: ptr FFIContext,
#     peerAddr: cstring,
#     timeoutMs: cuint,
#     callback: FFICallBack,
#     userData: pointer,
# ): cint {.dynlib, exportc.} =
#   initializeLibrary()
#   checkLibwakuParams(ctx, callback, userData)

#   handleRequest(
#     ctx,
#     RequestType.PING,
#     PingRequest.createShared(peerAddr, chronos.milliseconds(timeoutMs)),
#     callback,
#     userData,
#   )

# proc waku_is_online(
#     ctx: ptr FFIContext, callback: FFICallBack, userData: pointer
# ): cint {.dynlib, exportc.} =
#   initializeLibrary()
#   checkLibwakuParams(ctx, callback, userData)

#   handleRequest(
#     ctx,
#     RequestType.DEBUG,
#     DebugNodeRequest.createShared(DebugNodeMsgType.RETRIEVE_ONLINE_STATE),
#     callback,
#     userData,
#   )

# ### End of exported procs
# ################################################################################
