import chronos
import httpcore, urlly
import mofuparser, parseutils, strutils
import router

type
  Request* = ref object
    meth*: HttpMethod
    headers*: HttpHeaders
    protocol*: tuple[orig: string, major, minor: int]
    url*: Url
    hostname*: string
    transp: StreamTransport
    buf: array[1024,char]

  AsyncCallback = proc (request: Request): Future[void] {.closure, gcsafe.}
  Looper* = ref object of StreamServer
    callback: AsyncCallback
    maxBody: int
    router: Router[AsyncCallback]


proc addHeaders(msg: var string, headers: HttpHeaders) =
  for k, v in headers:
    msg.add(k & ": " & v & "\c\L")

proc resp*(req: Request, content: string,
              headers: HttpHeaders = nil, code: HttpCode = 200.HttpCode): Future[void] {.async.}=
  ## Responds to the request with the specified ``HttpCode``, headers and
  ## content.
 
  var msg = "HTTP/1.1 " & $code & "\c\L"

  if headers != nil:
    msg.addHeaders(headers)

  # If the headers did not contain a Content-Length use our own
  if headers.isNil() or not headers.hasKey("Content-Length"):
    msg.add("Content-Length: ")
    # this particular way saves allocations:
    msg.addInt content.len
    msg.add "\c\L"

  msg.add "\c\L"
  msg.add(content)
  discard await req.transp.write(msg)

proc respError(req: Request, code: HttpCode): Future[void] {.async.}=
  ## Responds to the request with the specified ``HttpCode``.
  let content = $code
  var msg = "HTTP/1.1 " & content & "\c\L"

  msg.add("Content-Length: " & $content.len & "\c\L\c\L")
  msg.add(content)
  discard await req.transp.write(msg)

proc sendStatus(transp: StreamTransport, status: string): Future[void] {.async.}=
  discard await transp.write("HTTP/1.1 " & status & "\c\L\c\L")

proc processRequest(
  looper: Looper,
  request: Request,
): Future[bool] {.async.} =

  request.headers.clear()
  request.hostname = $request.transp.localAddress
  # receivce untill http header end
  const HeaderSep = @[byte('\c'),byte('\L'),byte('\c'),byte('\L')]
  var count:int
  try:
    count = await request.transp.readUntil(request.buf[0].addr, len(request.buf), sep = HeaderSep)
  except TransportIncompleteError:
    return true
  # Headers
  var mfParser = MofuParser(headers:newSeqOfCap[MofuHeader](64))
  let headerEnd = mfParser.parseHeader(addr request.buf[0], request.buf.len)
  case mfParser.getMethod
    of "GET": request.meth = HttpGet
    of "POST": request.meth = HttpPost
    of "HEAD": request.meth = HttpHead
    of "PUT": request.meth = HttpPut
    of "DELETE": request.meth = HttpDelete
    of "PATCH": request.meth = HttpPatch
    of "OPTIONS": request.meth = HttpOptions
    of "CONNECT": request.meth = HttpConnect
    of "TRACE": request.meth = HttpTrace
  try:
    request.url = parseUrl(mfParser.getPath)
  except ValueError:
    asyncCheck request.respError(Http400)
    return true
  case mfParser.minor[]:
    of '0': 
      request.protocol.major = 1
      request.protocol.minor = 0
    of '1':
      request.protocol.major = 1
      request.protocol.minor = 1
    else:
      discard
  request.headers = mfParser.toHttpHeaders
  # Ensure the client isn't trying to DoS us.
  if request.headers.len > headerLimit:
    await request.transp.sendStatus("400 Bad Request")
    request.transp.close()
    return false

  if request.meth == HttpPost:
    # Check for Expect header
    if request.headers.hasKey("Expect"):
      if "100-continue" in request.headers["Expect"]:
        await request.transp.sendStatus("100 Continue")
      else:
        await request.transp.sendStatus("417 Expectation Failed")

  # Read the body
  # - Check for Content-length header
  if request.headers.hasKey("Content-Length"):
    var contentLength = 0
    if parseSaturatedNatural(request.headers["Content-Length"], contentLength) == 0:
      await request.resp("Bad Request. Invalid Content-Length.", code = Http400 )
      return true
    else:
      if contentLength > looper.maxBody:
        await request.respError(code = Http413)
        return false
      await request.transp.readExactly(addr request.buf[count],contentLength)
      if request.buf.len != contentLength:
        await request.resp("Bad Request. Content-Length does not match actual.", code = Http400)
        return true
  elif request.meth == HttpPost:
    await request.resp("Content-Length required.", code = Http411)
    return true

  # Call the user's callback.
  if looper.callback != nil:
    await looper.callback(request)
  elif looper.router != nil:
    let matched = looper.router.match($request.meth,request.url)
    if matched.success:
      await matched.handler(request)

  if "upgrade" in request.headers.getOrDefault("connection"):
    return false

  # The request has been served, from this point on returning `true` means the
  # connection will not be closed and will be kept in the connection pool.

  # Persistent connections
  if (request.protocol == HttpVer11 and
      cmpIgnoreCase(request.headers.getOrDefault("connection"), "close") != 0) or
     (request.protocol == HttpVer10 and
      cmpIgnoreCase(request.headers.getOrDefault("connection"), "keep-alive") == 0):
    # In HTTP 1.1 we assume that connection is persistent. Unless connection
    # header states otherwise.
    # In HTTP 1.0 we assume that the connection should not be persistent.
    # Unless the connection header states otherwise.
    return true
  else:
    request.transp.close()
    return false

proc processClient(server: StreamServer, transp: StreamTransport) {.async.} =
  var looper = cast[Looper](server)
  var req = Request()
  req.headers = newHttpHeaders()
  req.transp = transp
  while not transp.atEof():
    let retry = await processRequest(
      looper, req
    )
    if not retry: 
      transp.close
      break

proc serve*(address: string,
            callback: AsyncCallback,
            flags: set[ServerFlags] = {ReuseAddr}
            ) {.async.} =
  var looper = Looper()
  looper.callback = callback
  let address = initTAddress(address)
  let pserver = createStreamServer(address, processClient, flags, child = cast[StreamServer](looper))
  pserver.start()
  await pserver.join()

proc newLooper*(address: string, handler:AsyncCallback | Router[AsyncCallback], flags: set[ServerFlags] = {ReuseAddr}): Looper =
  new result
  when handler is AsyncCallback:
    result.callback = handler
  elif handler is Router[AsyncCallback]:
    result.router = handler
  let address = initTAddress(address)
  result = cast[Looper](createStreamServer(address, processClient, flags, child = cast[StreamServer](result)))
