import puppy/common, std/strutils, utils, windefs, zippy
from winversion import getWindowsVersionEx

proc internalFetch*(req: Request): Response {.raises: [PuppyError].} =
  result = Response()

  var hSession, hConnect, hRequest: HINTERNET
  try:
    let wideUserAgent = req.headers["user-agent"].wstr()
    {.cast(raises:[]).}:
      let infoEx = getWindowsVersionEx()
    let lessThan63 = infoEx.dwMajorVersion < 6 or infoEx.dwMajorVersion == 6 and infoEx.dwMinorVersion <= 3
    let dwAccessType = if lessThan63: WINHTTP_ACCESS_TYPE_DEFAULT_PROXY else: WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY
    hSession = WinHttpOpen(
      cast[ptr WCHAR](wideUserAgent[0].unsafeAddr),
      dwAccessType.DWORD,
      nil,
      nil,
      0
    )
    if hSession == nil:
      raise newException(
        PuppyError, "WinHttpOpen error: " & $GetLastError()
      )

    let ms = (req.timeout * 1000).int32
    if WinHttpSetTimeouts(hSession, ms, ms, ms, ms) == 0:
      raise newException(
        PuppyError, "WinHttpSetTimeouts error: " & $GetLastError()
      )

    var port: INTERNET_PORT
    if req.url.port == "":
      case req.url.scheme:
      of "http":
        port = 80
      of "https":
        port = 443
      else:
        discard # Scheme is validated above
    else:
      try:
        let parsedPort = parseInt(req.url.port)
        if parsedPort < 0 or parsedPort > uint16.high.int:
          raise newException(PuppyError, "Invalid port: " & req.url.port)
        port = parsedPort.uint16
      except ValueError as e:
        raise newException(PuppyError, "Parsing port failed", e)

    let wideHostname = req.url.hostname.wstr()

    hConnect = WinHttpConnect(
      hSession,
      cast[ptr WCHAR](wideHostname[0].unsafeAddr),
      port,
      0
    )
    if hConnect == nil:
      raise newException(
        PuppyError, "WinHttpConnect error: " & $GetLastError()
      )

    var openRequestFlags: DWORD
    if req.url.scheme == "https":
      openRequestFlags = openRequestFlags or WINHTTP_FLAG_SECURE

    var objectName = req.url.path
    if req.url.query.len > 0:
      objectName &= "?" & $req.url.query

    let
      wideVerb = req.verb.toUpperAscii().wstr()
      wideObjectName = objectName.wstr()

    let
      defaultAcceptType = "*/*".wstr()
      defaultacceptTypes = [
        cast[ptr WCHAR](defaultAcceptType[0].unsafeAddr),
        nil
      ]

    hRequest = WinHttpOpenRequest(
      hConnect,
      cast[ptr WCHAR](wideVerb[0].unsafeAddr),
      cast[ptr WCHAR](wideObjectName[0].unsafeAddr),
      nil,
      nil,
      cast[ptr ptr WCHAR](defaultacceptTypes.unsafeAddr),
      openRequestFlags.DWORD
    )
    if hRequest == nil:
      raise newException(
        PuppyError, "WinHttpOpenRequest error: " & $GetLastError()
      )

    var requestHeaderBuf: string
    for (k, v) in req.headers:
      requestHeaderBuf &= k & ": " & v & CRLF

    let wideRequestHeaderBuf = requestHeaderBuf.wstr()

    if WinHttpAddRequestHeaders(
      hRequest,
      cast[ptr WCHAR](wideRequestHeaderBuf[0].unsafeAddr),
      -1,
      (WINHTTP_ADDREQ_FLAG_ADD or WINHTTP_ADDREQ_FLAG_REPLACE).DWORD
    ) == 0:
      raise newException(
        PuppyError, "WinHttpAddRequestHeaders error: " & $GetLastError()
      )

    if WinHttpSendRequest(
      hRequest,
      nil,
      0,
      req.body.cstring,
      req.body.len.DWORD,
      req.body.len.DWORD,
      0
    ) == 0:

      let error = GetLastError()
      if error in [
        ERROR_WINHTTP_SECURE_FAILURE,
        ERROR_INTERNET_INVALID_CA,
        ERROR_INTERNET_SEC_CERT_DATE_INVALID,
        ERROR_INTERNET_SEC_INVALID_CERT,
        ERROR_INTERNET_SEC_CERT_CN_INVALID,
        ERROR_INTERNET_SEC_CERT_NO_REV,
        ERROR_INTERNET_SEC_CERT_REV_FAILED,
        ERROR_INTERNET_SEC_CERT_REVOKED,
        ERROR_INTERNET_SEC_CERT_ERRORS
      ] and req.allowAnyHttpsCertificate:
        # If this is a certificate error but we should allow any HTTPS cert,
        # we need to set some options and retry sending the request.
        # https://stackoverflow.com/questions/19338395/how-do-you-use-winhttp-to-do-ssl-with-a-self-signed-cert
        var flags: DWORD =
          SECURITY_FLAG_IGNORE_UNKNOWN_CA or
          SECURITY_FLAG_IGNORE_CERT_WRONG_USAGE or
          SECURITY_FLAG_IGNORE_CERT_CN_INVALID or
          SECURITY_FLAG_IGNORE_CERT_DATE_INVALID
        if WinHttpSetOption(
          hRequest,
          WINHTTP_OPTION_SECURITY_FLAGS,
          flags.addr,
          sizeof(flags).DWORD
        ) == 0:
          raise newException(
            PuppyError, "WinHttpSetOption error: " & $GetLastError()
          )

        if WinHttpSendRequest(
          hRequest,
          nil,
          0,
          req.body.cstring,
          req.body.len.DWORD,
          req.body.len.DWORD,
          0
        ) == 0:
          raise newException(
            PuppyError, "WinHttpSendRequest error: " & $GetLastError()
          )
      else:
        raise newException(
          PuppyError, "WinHttpSendRequest error: " & $GetLastError()
        )

    if WinHttpReceiveResponse(hRequest, nil) == 0:
      raise newException(
        PuppyError, "WinHttpReceiveResponse error: " & $GetLastError()
      )

    var
      statusCode: DWORD
      dwSize = sizeof(DWORD).DWORD
    if WinHttpQueryHeaders(
      hRequest,
      WINHTTP_QUERY_STATUS_CODE or WINHTTP_QUERY_FLAG_NUMBER,
      nil,
      statusCode.addr,
      dwSize.addr,
      nil
    ) == 0:
      raise newException(
        PuppyError, "WinHttpQueryHeaders error: " & $GetLastError()
      )

    result.code = statusCode
    var
      responseUrlBytes: DWORD
      responseUrlBuf: string

    # Determine how big the URL buffer needs to be
    discard WinHttpQueryOption(
      hRequest,
      WINHTTP_OPTION_URL,
      nil,
      responseUrlBytes.addr
    )
    var errorCode = GetLastError()
    if errorCode == ERROR_INSUFFICIENT_BUFFER: # Expected!
      # Set the URL buffer to the correct size and inclue a null terminator
      responseUrlBuf.setLen(responseUrlBytes)
    else:
      raise newException(PuppyError, "WinHttpQueryOption error: " & $errorCode)

    # Read the URL into the buffer
    if WinHttpQueryOption(
      hRequest,
      WINHTTP_OPTION_URL,
      responseUrlBuf[0].addr,
      responseUrlBytes.addr,
    ) == 0:
      raise newException(PuppyError, "WinHttpQueryOption error: " & $errorCode)

    result.url = $cast[ptr WCHAR](responseUrlBuf[0].addr)

    var
      responseHeaderBytes: DWORD
      responseHeaderBuf: string

    # Determine how big the header buffer needs to be
    discard WinHttpQueryHeaders(
      hRequest,
      WINHTTP_QUERY_RAW_HEADERS_CRLF,
      nil,
      nil,
      responseHeaderBytes.addr,
      nil
    )
    errorCode = GetLastError()
    if errorCode == ERROR_INSUFFICIENT_BUFFER: # Expected!
      # Set the header buffer to the correct size and inclue a null terminator
      responseHeaderBuf.setLen(responseHeaderBytes)
    else:
      raise newException(PuppyError, "HttpQueryInfoW error: " & $errorCode)

    # Read the headers into the buffer
    if WinHttpQueryHeaders(
      hRequest,
      WINHTTP_QUERY_RAW_HEADERS_CRLF,
      nil,
      responseHeaderBuf[0].addr,
      responseHeaderBytes.addr,
      nil
    ) == 0:
      raise newException(PuppyError, "HttpQueryInfoW error: " & $errorCode)

    let responseHeaders =
      ($cast[ptr WCHAR](responseHeaderBuf[0].addr)).split(CRLF)

    if responseHeaders.len == 0:
      raise newException(PuppyError, "Error parsing response headers")

    for i, line in responseHeaders:
      if i == 0: # HTTP/1.1 200 OK
        continue
      if line != "":
        let parts = line.split(":", 1)
        if parts.len == 2:
          when (NimMajor, NimMinor, NimPatch) >= (1, 4, 8):
            result.headers.add((parts[0].strip(), parts[1].strip()))
          else:
            let tmp = cast[ptr HttpHeaders](result.headers.addr)
            tmp[].toBase.add((parts[0].strip(), parts[1].strip()))

    var i: int
    result.body.setLen(8192)

    while true:
      var bytesRead: DWORD
      if WinHttpReadData(
        hRequest,
        result.body[i].addr,
        (result.body.len - i).DWORD,
        bytesRead.addr
      ) == 0:
        raise newException(
          PuppyError, "WinHttpReadData error: " & $GetLastError()
        )
      i += bytesRead
      if bytesRead == 0:
        break

      if i == result.body.len:
        result.body.setLen(i * 2)

    result.body.setLen(i)

    if result.headers["content-encoding"].toLowerAscii() == "gzip":
      try:
        result.body = uncompress(result.body, dfGzip)
      except ZippyError as e:
        raise newException(PuppyError, "Error uncompressing response", e)
  finally:
    discard WinHttpCloseHandle(hRequest)
    discard WinHttpCloseHandle(hConnect)
    discard WinHttpCloseHandle(hSession)
