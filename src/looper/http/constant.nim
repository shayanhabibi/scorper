import netunit

const HttpRequestBufferSize* {.intdefine.} = 2.Kb
const BufferLimitExceeded* = "Buffer Limit Exceeded" 
const ContentLengthMismatch* = "Content-Length does not match actual"
const HttpHeadersLength* {.intdefine.} = int(HttpRequestBufferSize / 32) # 32 is sizeof MofuHeader