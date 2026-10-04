--[[=============================================================================
    DirectorLink Hikvision - ISAPI client
    Digest/Basic authentication and HTTP requests to a Hikvision device ("target").

    A target is a table:
      { host, port, https, user, pass, name,
        auth = NewAuth(), authFailed = false, onAuthChange = function(target, failed) end }

    Lockout safety: a wrong password costs at most one failed login per request,
    and once a target is marked authFailed no further logins are attempted until
    the credentials change (NewTargetCredentials) or a request passes force = true.

    Copyright 2026 DirectorLink
    SPDX-License-Identifier: Apache-2.0
===============================================================================]]

function NewAuth()
	return { scheme = nil, nc = 0 }
end

-- hdr: string, or array of strings when the header was repeated.
-- Returns parsed(bool), nonceChanged(bool)
function ParseChallenge(ctx, hdr)
	local list = type(hdr) == "table" and hdr or { hdr }
	local digest, basic
	for _, h in ipairs(list) do
		if type(h) == "string" then
			local d = string.match(h, "[Dd][Ii][Gg][Ee][Ss][Tt]%s+(.*)")
			if d then
				digest = d
			elseif string.find(string.lower(h), "basic", 1, true) then
				basic = true
			end
		end
	end
	if digest then
		local p = {}
		for k, v in string.gmatch(digest, '([%w%-]+)%s*=%s*"([^"]*)"') do p[string.lower(k)] = v end
		for k, v in string.gmatch(digest, '([%w%-]+)%s*=%s*([^",%s]+)') do
			if p[string.lower(k)] == nil then p[string.lower(k)] = v end
		end
		if not p.nonce then return false, false end
		local changed = (p.nonce ~= ctx.nonce)
		ctx.scheme = "digest"
		ctx.realm = p.realm or ""
		ctx.nonce = p.nonce
		ctx.opaque = p.opaque
		ctx.algorithm = p.algorithm
		ctx.stale = string.lower(p.stale or "") == "true"
		ctx.qop = nil
		if p.qop then
			for q in string.gmatch(p.qop, "[^,%s]+") do
				if string.lower(q) == "auth" then ctx.qop = "auth" end
			end
		end
		ctx.nc = 0
		return true, changed
	elseif basic then
		local changed = ctx.scheme ~= "basic"
		ctx.scheme = "basic"
		return true, changed
	end
	return false, false
end

function AuthHeader(ctx, method, uri, user, pass)
	user, pass = user or "", pass or ""
	if ctx.scheme == "basic" then
		return "Basic " .. C4:Base64Encode(user .. ":" .. pass)
	end
	if ctx.scheme ~= "digest" then return nil end
	ctx.nc = ctx.nc + 1
	local nc = string.format("%08x", ctx.nc)
	local cnonce = string.sub(Md5(tostring(os.time()) .. tostring(math.random()) .. uri), 1, 16)
	local ha1 = Md5(user .. ":" .. ctx.realm .. ":" .. pass)
	if string.lower(ctx.algorithm or "") == "md5-sess" then
		ha1 = Md5(ha1 .. ":" .. ctx.nonce .. ":" .. cnonce)
	end
	local ha2 = Md5(method .. ":" .. uri)
	local response
	if ctx.qop then
		response = Md5(ha1 .. ":" .. ctx.nonce .. ":" .. nc .. ":" .. cnonce .. ":" .. ctx.qop .. ":" .. ha2)
	else
		response = Md5(ha1 .. ":" .. ctx.nonce .. ":" .. ha2)
	end
	local parts = {
		'username="' .. user .. '"',
		'realm="' .. ctx.realm .. '"',
		'nonce="' .. ctx.nonce .. '"',
		'uri="' .. uri .. '"',
		'response="' .. response .. '"',
	}
	if ctx.algorithm then parts[#parts + 1] = "algorithm=" .. ctx.algorithm end
	if ctx.opaque then parts[#parts + 1] = 'opaque="' .. ctx.opaque .. '"' end
	if ctx.qop then
		parts[#parts + 1] = "qop=" .. ctx.qop
		parts[#parts + 1] = "nc=" .. nc
		parts[#parts + 1] = 'cnonce="' .. cnonce .. '"'
	end
	return "Digest " .. table.concat(parts, ", ")
end

function HeaderValue(headers, name)
	if type(headers) ~= "table" then return nil end
	name = string.lower(name)
	for k, v in pairs(headers) do
		if string.lower(tostring(k)) == name then return v end
	end
	return nil
end

--[[------------------------------------------------------------------ Targets ]]
function NewTarget(t)
	t = t or {}
	t.host = t.host or ""
	t.port = tonumber(t.port) or 80
	t.https = t.https and true or false
	t.user = t.user or ""
	t.pass = t.pass or ""
	t.auth = NewAuth()
	t.authFailed = false
	return t
end

function SetTargetCredentials(t, user, pass)
	if t.user ~= (user or "") or t.pass ~= (pass or "") then
		t.user = user or ""
		t.pass = pass or ""
		t.auth = NewAuth()
		SetTargetAuthFailed(t, false)
	end
end

function SetTargetAuthFailed(t, failed)
	if t.authFailed == failed then return end
	t.authFailed = failed
	if failed then
		LogError("Login failed for '%s' on %s - check the username and password", t.user, t.name or t.host)
	end
	if t.onAuthChange then pcall(t.onAuthChange, t, failed) end
end

function TargetBaseUrl(t, withCredentials)
	local creds = ""
	if withCredentials and t.user ~= "" then creds = UrlEncode(t.user) .. ":" .. UrlEncode(t.pass) .. "@" end
	if t.https then return "https://" .. creds .. HostPort(t.host, t.port, 443) end
	return "http://" .. creds .. HostPort(t.host, t.port, 80)
end

--[[------------------------------------------------------------------ HTTP
    Isapi(target, method, path, body, cb, opts)
    cb(code, body, err, headers). opts: noAuth, force, timeout

    Requests to one device run one at a time: Hikvision rejects Digest requests
    that overlap (nonce counter out of order), which would look like a wrong
    password. A guard timer keeps the queue moving if a transfer never ends.   ]]
local IsapiNow -- forward

local function IsapiNext(t)
	local job = table.remove(t.queue, 1)
	if not job then
		t.busy = false
		return
	end
	t.busy = true
	local finished = false
	local guard
	local function finish(...)
		if finished then return end
		finished = true
		if guard then pcall(function() guard:Cancel() end) end
		local ok, err = pcall(job.cb, ...)
		if not ok then LogError("ISAPI callback failed: %s", err) end
		IsapiNext(t)
	end
	guard = C4:SetTimer(((job.opts.timeout or 20) + 10) * 1000, function() finish(nil, nil, "no answer") end)
	IsapiNow(t, job.method, job.path, job.body, finish, job.opts)
end

function Isapi(t, method, path, body, cb, opts)
	t.queue = t.queue or {}
	table.insert(t.queue, { method = method, path = path, body = body, cb = cb or function() end, opts = opts or {} })
	if not t.busy then IsapiNext(t) end
end

IsapiNow = function(t, method, path, body, cb, opts)
	opts = opts or {}
	cb = cb or function() end
	if not ValidAddress(t.host) then
		cb(nil, nil, "address not set")
		return
	end
	if not opts.noAuth then
		if t.user == "" then
			cb(nil, nil, "username not set")
			return
		end
		if t.authFailed and not opts.force then
			cb(nil, nil, "login failed earlier (fix the username/password)")
			return
		end
	end
	local tries = 0
	local function send()
		tries = tries + 1
		local headers = { ["Accept"] = "*/*", ["User-Agent"] = UserAgent() }
		if body then headers["Content-Type"] = 'application/xml; charset="UTF-8"' end
		local sentAuth = false
		if not opts.noAuth then
			local a = AuthHeader(t.auth, method, path, t.user, t.pass)
			if a then
				headers["Authorization"] = a
				sentAuth = true
			end
		end
		local url = TargetBaseUrl(t) .. path
		LogTrace("HTTP %s %s", method, url)
		local ok, err = pcall(function()
			local x = C4:url()
			x:SetOptions({
				fail_on_error = false,
				timeout = opts.timeout or 20,
				connect_timeout = 5,
				ssl_verify_host = false,
				ssl_verify_peer = false,
				response_headers_duplicates = true,
			})
			x:OnDone(function(_, responses, errCode, errMsg)
				local resp = responses and responses[#responses]
				if (errCode ~= nil and errCode ~= 0) or resp == nil then
					LogDebug("HTTP %s %s%s failed: %s", method, t.host, path, errMsg or errCode)
					cb(nil, nil, errMsg or ("transfer error " .. tostring(errCode)))
					return
				end
				local code = tonumber(resp.code) or 0
				LogTrace("HTTP %s %s -> %d", method, path, code)
				if code == 401 and not opts.noAuth then
					local parsed = ParseChallenge(t.auth, HeaderValue(resp.headers, "WWW-Authenticate"))
					-- Retry once with the fresh challenge (or once more if the nonce was only stale)
					if parsed and (tries == 1 or (tries == 2 and t.auth.stale)) then
						send()
						return
					end
					SetTargetAuthFailed(t, true)
					cb(code, resp.body or "", "login failed", resp.headers)
					return
				end
				if sentAuth and code >= 200 and code < 300 then SetTargetAuthFailed(t, false) end
				cb(code, resp.body or "", nil, resp.headers)
			end)
			if method == "GET" then
				x:Get(url, headers)
			elseif method == "PUT" then
				x:Put(url, body or "", headers)
			elseif method == "POST" then
				x:Post(url, body or "", headers)
			else
				x:Custom(url, method, body or "", headers)
			end
		end)
		if not ok then
			LogError("HTTP request error: %s", err)
			cb(nil, nil, tostring(err))
		end
	end
	send()
end

-- Hikvision answers some failures with HTTP 200 + <ResponseStatus>; normalise that.
function IsOkResponse(code, body)
	if code ~= 200 then return false end
	if body and string.find(body, "<ResponseStatus", 1, true) then
		local sc = string.match(body, "<statusCode>%s*(%d+)%s*</statusCode>")
		return sc == nil or sc == "1"
	end
	return true
end

function ResponseError(code, body, err)
	if err then return err end
	local s = body and (string.match(body, "<subStatusCode>([^<]*)</subStatusCode>") or string.match(body, "<statusString>([^<]*)</statusString>"))
	return "HTTP " .. tostring(code) .. (s and (" (" .. s .. ")") or "")
end

function IsJpeg(body)
	return type(body) == "string" and string.sub(body, 1, 2) == "\255\216"
end

-- Width and height from a JPEG's frame header (nil when not found)
function JpegSize(data)
	if not IsJpeg(data) then return nil end
	local i, n = 3, #data
	while i + 8 <= n do
		if string.byte(data, i) ~= 0xFF then return nil end
		local marker = string.byte(data, i + 1)
		if marker == 0xFF then
			i = i + 1 -- fill byte
		else
			if marker >= 0xC0 and marker <= 0xCF and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
				local h = string.byte(data, i + 5) * 256 + string.byte(data, i + 6)
				local w = string.byte(data, i + 7) * 256 + string.byte(data, i + 8)
				return w, h
			end
			i = i + 2 + string.byte(data, i + 2) * 256 + string.byte(data, i + 3)
		end
	end
	return nil
end

-- GET a document, replace fields, PUT it back. changes = { { tag, value }, ... }
function ReadModifyWrite(t, path, changes, label, cb)
	Isapi(t, "GET", path, nil, function(code, body, err)
		if code ~= 200 or not body or body == "" then
			LogError("%s: cannot read %s: %s", label, path, ResponseError(code, body, err))
			if cb then cb(false) end
			return
		end
		local doc = body
		for _, c in ipairs(changes) do
			local replaced
			doc, replaced = XmlReplaceValue(doc, c[1], c[2])
			if not replaced then
				LogError("%s: this camera does not support <%s>", label, c[1])
				if cb then cb(false) end
				return
			end
		end
		Isapi(t, "PUT", path, doc, function(pcode, pbody, perr)
			local ok = IsOkResponse(pcode, pbody)
			if ok then
				LogInfo("%s: OK", label)
			else
				LogError("%s failed: %s", label, ResponseError(pcode, pbody, perr))
			end
			if cb then cb(ok) end
		end)
	end)
end

--[[------------------------------------------------------------------ Device info helpers ]]
function ParseDeviceInfo(body)
	local d = XmlParse(body or "")
	local info = {
		name = XmlGet(d, "deviceName") or "",
		model = XmlGet(d, "model") or "",
		serial = XmlGet(d, "serialNumber") or "",
		mac = XmlGet(d, "macAddress") or "",
		firmware = trim((XmlGet(d, "firmwareVersion") or "") .. " " .. (XmlGet(d, "firmwareReleasedDate") or "")),
		deviceType = XmlGet(d, "deviceType") or "",
	}
	local dt = string.upper(info.deviceType)
	info.isRecorder = (string.find(dt, "NVR", 1, true) or string.find(dt, "DVR", 1, true) or string.find(dt, "HVR", 1, true)) ~= nil
	return info
end

-- Names Hikvision ships as defaults are not useful as Control4 device names
function IsGenericCameraName(name)
	local n = string.lower(trim(name or ""))
	return n == "" or n == "ip camera" or n == "ipcamera" or n == "camera" or n == "embedded net dvr"
		or string.match(n, "^camera%s*%d*$") ~= nil or string.match(n, "^ipcamera%s*%d*$") ~= nil
		or string.match(n, "^ip camera%s*%d*$") ~= nil or string.match(n, "^ipdome%s*%d*$") ~= nil
		or string.match(n, "^network video recorder") ~= nil
end
