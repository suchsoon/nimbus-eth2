{.push raises: [].}

import
  results,
  chronos,
  libp2p/switch,
  ../spec/[eth2_ssz_serialization, network]

type
  ErrorMsg = List[byte, 256]
  Eth2Node = ref object of RootObj
    switch: Switch
    protocols: seq[ProtocolInfo]

  Peer = ref object
    network: Eth2Node
    connectionState: ConnectionState
    protocolStates: seq[RootRef]

  ConnectionState = enum
    None,
    Connecting,
    Connected,
    Disconnecting,
    Disconnected

  MessageInfo = object
    protocolMounter: MounterProc

  ProtocolInfoObj = object
    name: string
    messages: seq[MessageInfo]
    index: int # the position of the protocol in the
                # ordered list of supported protocols

    peerStateInitializer: PeerStateInitializer
    networkStateInitializer: NetworkStateInitializer
    onPeerConnected: OnPeerConnectedHandler
    onPeerDisconnected: OnPeerDisconnectedHandler

  ProtocolInfo = ptr ProtocolInfoObj

  ResponseCode = enum
    Success
    InvalidRequest
    ServerError
    ResourceUnavailable

  PeerStateInitializer = proc(peer: Peer): RootRef {.gcsafe, raises: [].}
  NetworkStateInitializer = proc(network: Eth2Node): RootRef {.gcsafe, raises: [].}
  OnPeerConnectedHandler = proc(peer: Peer, incoming: bool): Future[void] {.async: (raises: [CancelledError]).}
  OnPeerDisconnectedHandler = proc(peer: Peer): Future[void] {.async: (raises: [CancelledError]).}
  MounterProc = proc(network: Eth2Node) {.gcsafe, raises: [].}

  Eth2NetworkingErrorKind = enum
    BrokenConnection
    ReceivedErrorResponse
    UnexpectedEOF
    PotentiallyExpectedEOF
    StreamOpenTimeout
    ReadResponseTimeout

    UnknownError

  Eth2NetworkingError = object
    case kind: Eth2NetworkingErrorKind
    of ReceivedErrorResponse:
      responseCode: ResponseCode
      errorMsg: string
    else:
      discard

  InvalidInputsError = object of CatchableError

  ResourceUnavailableError = object of CatchableError

  NetRes[T] = Result[T, Eth2NetworkingError]

const
  libp2p_pki_schemes {.strdefine.} = ""

when libp2p_pki_schemes != "secp256k1":
  {.fatal: "Incorrect building process, please use -d:\"libp2p_pki_schemes=secp256k1\"".}

func shortProtocolId(protocolId: string): string = discard
proc getPeer(node: Eth2Node, peerId: PeerId): Peer = discard
proc peerFromStream(network: Eth2Node, conn: Connection): Peer =
  result = network.getPeer(conn.peerId)

func `<`(a, b: Peer): bool = false
const
  maxRequestQuota = 1000000
  fullReplenishTime = 5.seconds

template awaitQuota(peerParam: Peer, costParam: float, protocolIdParam: string) = discard

template awaitQuota(
    networkParam: Eth2Node, costParam: float, protocolIdParam: string) =
  let
    network = networkParam
    cost = int(costParam)

  if not network.quota.tryConsume(cost.int):
    let protocolId = protocolIdParam
    nbc_reqresp_messages_throttled.inc(1, [protocolId])
    await network.quota.consume(cost.int)

func allowedOpsPerSecondCost(n: int): float =
  const replenishRate = (maxRequestQuota / fullReplenishTime.nanoseconds.float)
  (replenishRate * 1000000000'f / n.float)

const
  libp2pRequestCost = allowedOpsPerSecondCost(8)

proc sendErrorResponse(peer: Peer,
                       conn: Connection,
                       responseCode: ResponseCode,
                       errMsg: ErrorMsg): Future[void] = discard
proc uncompressFramedStream(conn: Connection,
                            expectedSize: int): Future[Result[seq[byte], string]]
                            {.async: (raises: [CancelledError]).} = discard
proc readChunkPayload(conn: Connection, peer: Peer,
                       MsgType: type): Future[NetRes[MsgType]]
                       {.async: (raises: [CancelledError]).} =
  let size = 0'u32
  let
    dataRes = await conn.uncompressFramedStream(size.int)

  try:
    ok SSZ.decode(dataRes.get, MsgType)
  except SerializationError:
    raiseAssert "false"

proc handleIncomingStream(network: Eth2Node,
                          conn: Connection,
                          protocolId: string,
                          MsgType: type) {.async: (raises: [CancelledError]).} =
  mixin callUserHandler, RecType

  type MsgRec = RecType(MsgType)
  const msgName {.used.} = typetraits.name(MsgType)


  let peer = peerFromStream(network, conn)
  try:
    case peer.connectionState
    of Disconnecting, Disconnected, None:
      return
    of Connecting:
      discard
    of Connected:
      discard

    template returnInvalidRequest(msg: ErrorMsg) =
      await sendErrorResponse(peer, conn, InvalidRequest, msg)
      return

    template returnInvalidRequest(msg: string) =
      returnInvalidRequest(default(ErrorMsg))

    template returnResourceUnavailable(msg: ErrorMsg) =
      await sendErrorResponse(peer, conn, ResourceUnavailable, msg)
      return

    template returnResourceUnavailable(msg: string) =
      returnResourceUnavailable(default(ErrorMsg))

    const isEmptyMsg = when MsgRec is object:
      when totalSerializedFields(MsgRec) == 0: true
      else: false
    else:
      false

    let msg =
      try:
        when isEmptyMsg:
          NetRes[MsgRec].ok default(MsgRec)
        else:
          await(readChunkPayload(conn, peer, MsgRec))
      finally:
        awaitQuota(peer, libp2pRequestCost, shortProtocolId(protocolId))

    try:
      discard
    except InvalidInputsError as exc:
      returnInvalidRequest exc.msg
    except ResourceUnavailableError as exc:
      returnResourceUnavailable exc.msg
    except CatchableError:
      await sendErrorResponse(peer, conn, ServerError, default(ErrorMsg))

  except CatchableError:
    discard

type
  beaconBlocksByRange_v2Obj = object
    reqCount: uint64
    reqStep: uint64

template RecType(MSG: type beaconBlocksByRange_v2Obj): untyped =
  beaconBlocksByRange_v2Obj

proc beaconBlocksByRange_v2Mounter(network: Eth2Node) {.raises: [].} =
  proc snappyThunk(stream: Connection; protocol: string): Future[void] {.gcsafe.} =
    return handleIncomingStream(network, stream, protocol,
                                beaconBlocksByRange_v2Obj)

  try:
    mount network.switch, LPProtocol.new(codecs = @[
        "/eth2/beacon_chain/req/beacon_blocks_by_range/2/ssz_snappy"],
        handler = snappyThunk)
  except LPError:
    raiseAssert "foo"
discard MessageInfo(protocolMounter: beaconBlocksByRange_v2Mounter)
