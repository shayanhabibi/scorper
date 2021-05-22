
import ./scorper/http/streamserver
import ./scorper/http/streamclient
import ./scorper/http/router
import ./scorper/http/httpcore, chronos
import tables

const TestUrl = "http://127.0.0.1:64124/basic/foo/ba?q=qux"
type AsyncCallback = proc (request: Request): Future[void] {.closure, gcsafe.}

proc runTest(
    handler: proc (request: Request): Future[void] {.gcsafe.},
    request: proc (server: Scorper): Future[AsyncResponse],
    test: proc (response: AsyncResponse, body: string): Future[void]) =

  let address = "127.0.0.1:64124"
  let flags = {ReuseAddr}
  let r = newRouter[AsyncCallback]()
  r.addRoute(handler, "get", "/basic/{p1}/{p2}")
  r.addRoute(handler, "get", "/code/{codex}")
  var server = newScorper(address, r, flags)
  server.start()
  let
    response = waitFor(request(server))
    body = waitFor(response.readBody())

  waitFor test(response, body)
  server.stop()
  server.close()
  waitFor server.join()

proc testParams() {.async.} =
  proc handler(request: Request) {.async.} =
    await request.resp($request.params & $request.query.toTable)

  proc request(server: Scorper): Future[AsyncResponse] {.async.} =
    let
      client = newAsyncHttpClient()
      clientResponse = await client.request(TestUrl)
    await client.close()

    return clientResponse

  proc test(response: AsyncResponse, body: string) {.async.} =
    doAssert(response.code == Http200)
    let p = {"p1": "foo", "p2": "ba"}.toTable
    let q = {"q": "qux"}.toTable
    echo body
    doAssert(body == $p & $q)
  try:
    runTest(handler, request, test)
  except:
    discard

proc testParamEncode() {.async.} =
  proc handler(request: Request) {.async.} =
    doAssert request.params["codex"] == "ß"
    await request.resp("")

  proc request(server: Scorper): Future[AsyncResponse] {.async.} =
    let
      client = newAsyncHttpClient()
      codeUrl = "http://127.0.0.1:64124/code/%C3%9F"
      clientResponse = await client.request(codeUrl)
    await client.close()

    return clientResponse

  proc test(response: AsyncResponse, body: string) {.async.} =
    doAssert(response.code == Http200)
  try:
    runTest(handler, request, test)
  except:
    discard

proc testParamRaw() {.async.} =
  proc handler(request: Request) {.async.} =
    doAssert request.params["code"] == "ß"
    await request.resp("")

  proc request(server: Scorper): Future[AsyncResponse] {.async.} =
    let
      client = newAsyncHttpClient()
      codeUrl = "http://127.0.0.1:64124/code/ß"
      clientResponse = await client.request(codeUrl)
    await client.close()

    return clientResponse

  proc test(response: AsyncResponse, body: string) {.async.} =
    doAssert(response.code == Http404)
  try:
    runTest(handler, request, test)
  except:
    discard

waitfor(testParams())
waitfor(testParamEncode())
waitfor(testParamRaw())


echo "OK"
