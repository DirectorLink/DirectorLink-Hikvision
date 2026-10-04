--[[=============================================================================
    DirectorLink Hikvision - shared core
    Logging, utilities, timers, variables/events and a namespace-agnostic XML parser.
    tools/build.py inlines this file at the top of each driver.lua.

    Copyright 2026 DirectorLink
    SPDX-License-Identifier: Apache-2.0
===============================================================================]]

unpack = unpack or table.unpack

-- Replaced by tools/build.py with the contents of the VERSION file
DRIVER_SEMVER = "dev"

-- HTTP User-Agent "<product>/<version>"; each driver sets its product (its .c4z file name)
USER_AGENT_PRODUCT = "DirectorLink-Hikvision"
function UserAgent()
	return USER_AGENT_PRODUCT .. "/" .. DRIVER_SEMVER
end

--[[------------------------------------------------------------------ Logging
    One "Log Level" property: Off, Errors, Warnings, Info, Debug, Trace.
    Output goes to the Lua tab; errors are also written to the controller log.  ]]
LOG_LEVEL = 2
local LEVEL_TAGS = { "ERROR", "WARN", "INFO", "DEBUG", "TRACE" }
local LEVELS = { Off = 0, Errors = 1, Warnings = 2, Info = 3, Debug = 4, Trace = 5 }

function Log(level, fmt, ...)
	if level > LOG_LEVEL then return end
	local msg
	local n = select("#", ...)
	if n > 0 then
		local args = { ... }
		for i = 1, n do
			if type(args[i]) ~= "number" then args[i] = tostring(args[i]) end
		end
		local ok, res = pcall(string.format, fmt, unpack(args, 1, n))
		msg = ok and res or (tostring(fmt) .. " (format error)")
	else
		msg = tostring(fmt)
	end
	local line = os.date("%H:%M:%S") .. " [" .. (LEVEL_TAGS[level] or "LOG") .. "] " .. msg
	print(line)
	if level <= 1 then pcall(function() C4:ErrorLog(line) end) end
end

function LogError(...) Log(1, ...) end
function LogWarn(...) Log(2, ...) end
function LogInfo(...) Log(3, ...) end
function LogDebug(...) Log(4, ...) end
function LogTrace(...) Log(5, ...) end

function ApplyLogSettings()
	LOG_LEVEL = LEVELS[Properties["Log Level"] or "Warnings"] or 2
end

--[[------------------------------------------------------------------ Utilities ]]
function trim(s)
	return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function toboolean(v)
	if type(v) == "boolean" then return v end
	v = string.lower(tostring(v or ""))
	return v == "true" or v == "1" or v == "yes" or v == "on" or v == "enabled"
end

function UpdateProperty(name, value)
	value = tostring(value == nil and "" or value)
	if Properties[name] ~= value then
		pcall(function() C4:UpdateProperty(name, value) end)
		Properties[name] = value
	end
end

function UrlEncode(s)
	return (tostring(s or ""):gsub("[^%w%-%._~]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

function XmlEscape(s)
	s = tostring(s or "")
	return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"):gsub("'", "&apos;"))
end

function Md5(s)
	local res, err = C4:Hash("MD5", s, { return_encoding = "HEX", data_encoding = "NONE" })
	if not res then
		LogError("MD5 failed: %s", err)
		return ""
	end
	return string.lower(res)
end

function HostPort(addr, port, default)
	port = tonumber(port)
	if port and port ~= default then return addr .. ":" .. port end
	return addr
end

-- A camera never lives on the controller itself; the camera proxy reports 127.0.0.1 until set.
function ValidAddress(a)
	if type(a) ~= "string" then return false end
	local l = string.lower(trim(a))
	if l == "" or l == "localhost" or l == "0.0.0.0" or l == "::1" or string.match(l, "^127%.") then
		return false
	end
	return true
end

function IsMasked(s)
	return type(s) == "string" and s ~= "" and string.match(s, "^%*+$") ~= nil
end

-- The Control4 camera proxy keeps passwords Base64 encoded; accept either form.
function MaybeBase64Decode(s)
	if type(s) ~= "string" or #s < 4 or #s % 4 ~= 0 or not string.match(s, "^[A-Za-z0-9+/]+=?=?$") then
		return s
	end
	local ok, d = pcall(function() return C4:Base64Decode(s) end)
	if not ok or type(d) ~= "string" or d == "" or not string.match(d, "^[\32-\126]+$") then return s end
	local ok2, again = pcall(function() return C4:Base64Encode(d) end)
	if not ok2 or again ~= s then return s end
	return d
end

function ProxyId()
	local ok, p = pcall(function() return C4:GetProxyDevices() end)
	if not ok or p == nil then return nil end
	if type(p) == "table" then
		for _, v in pairs(p) do return tonumber(v) end
		return nil
	end
	return tonumber(string.match(tostring(p), "%d+"))
end

function MyDeviceId()
	local ok, id = pcall(function() return C4:GetDeviceID() end)
	return ok and tonumber(id) or nil
end

-- Inter-driver message (hub <-> camera). Values are sent as strings; never logged by Director.
function SendToDriver(deviceId, command, params)
	if not deviceId then return false end
	local p = {}
	for k, v in pairs(params or {}) do p[k] = tostring(v) end
	local ok, err = pcall(function() C4:SendToDevice(tonumber(deviceId), command, p, true, false) end)
	if not ok then LogDebug("SendToDevice(%s, %s) failed: %s", deviceId, command, err) end
	return ok
end

--[[------------------------------------------------------------------ Timers ]]
local gTimers = {}

function SetTimer(name, ms, fn, rep)
	if gTimers[name] then
		pcall(function() gTimers[name]:Cancel() end)
		gTimers[name] = nil
	end
	gTimers[name] = C4:SetTimer(ms, function()
		if not rep then gTimers[name] = nil end
		local ok, err = pcall(fn)
		if not ok then LogError("Timer %s failed: %s", name, err) end
	end, rep and true or false)
end

function KillTimer(name)
	if gTimers[name] then
		pcall(function() gTimers[name]:Cancel() end)
		gTimers[name] = nil
	end
end

function KillAllTimers()
	for name in pairs(gTimers) do KillTimer(name) end
end

--[[------------------------------------------------------------------ Variables & events ]]
local gVarValues = {}

function AddVariables(list)
	for _, v in ipairs(list) do
		pcall(function() C4:AddVariable(v[1], v[2], v[3], true, false) end)
		gVarValues[v[1]] = v[2]
	end
end

function SetVar(name, value)
	if type(value) == "boolean" then value = value and "1" or "0" end
	value = tostring(value)
	if gVarValues[name] == value then return end
	gVarValues[name] = value
	pcall(function() C4:SetVariable(name, value) end)
end

function FireEvent(name)
	LogInfo("Event: %s", name)
	local ok, err = pcall(function() C4:FireEvent(name) end)
	if not ok then LogError("FireEvent(%s) failed: %s", name, err) end
end

-- BOOL conditionals: Director may pass the chosen text (true_text/false_text) and a LOGIC
function TestBool(state, tParams, trueText)
	local v = tParams and (tParams.VALUE or tParams.value)
	local result
	if v == nil then
		result = state
	else
		local lv = string.lower(tostring(v))
		local wantTrue = (lv == string.lower(trueText) or lv == "true" or lv == "1")
		result = (state == wantTrue)
	end
	if tParams and tParams.LOGIC == "NOT_EQUAL" then result = not result end
	return result
end

function TestEquals(actual, tParams)
	local eq = (tostring(actual or "") == tostring(tParams and tParams.VALUE or ""))
	if tParams and tParams.LOGIC == "NOT_EQUAL" then return not eq end
	return eq
end

--[[------------------------------------------------------------------ XML
    Small namespace-agnostic parser: Hikvision documents come with several
    namespaces (or none), so element names are matched by local name.        ]]
local XML_ENTITIES = { lt = "<", gt = ">", amp = "&", quot = '"', apos = "'" }

local function Utf8Char(n)
	if n < 0x80 then return string.char(n) end
	if n < 0x800 then return string.char(0xC0 + math.floor(n / 64), 0x80 + n % 64) end
	if n < 0x10000 then
		return string.char(0xE0 + math.floor(n / 4096), 0x80 + math.floor(n / 64) % 64, 0x80 + n % 64)
	end
	return string.char(0xF0 + math.floor(n / 262144), 0x80 + math.floor(n / 4096) % 64,
		0x80 + math.floor(n / 64) % 64, 0x80 + n % 64)
end

function XmlUnescape(s)
	return (s:gsub("&(#?)([xX]?)(%w+);", function(hash, x, v)
		if hash == "" then return XML_ENTITIES[v] or ("&" .. x .. v .. ";") end
		local n = (x ~= "") and tonumber(v, 16) or tonumber(v)
		if n then return Utf8Char(n) end
		return "&#" .. x .. v .. ";"
	end))
end

local function LocalName(n)
	return string.match(n, ":([^:]+)$") or n
end

function XmlParse(s)
	local root = { name = "#document", attr = {}, children = {}, text = "" }
	local stack = { root }
	local pos, len = 1, #s
	while pos <= len do
		local top = stack[#stack]
		local lt = string.find(s, "<", pos, true)
		if not lt then
			top.text = top.text .. string.sub(s, pos)
			break
		end
		if lt > pos then top.text = top.text .. string.sub(s, pos, lt - 1) end
		if string.sub(s, lt, lt + 3) == "<!--" then
			local e = string.find(s, "-->", lt + 4, true)
			pos = e and (e + 3) or (len + 1)
		elseif string.sub(s, lt, lt + 8) == "<![CDATA[" then
			local e = string.find(s, "]]>", lt + 9, true)
			top.text = top.text .. XmlEscape(string.sub(s, lt + 9, (e or (len + 1)) - 1))
			pos = e and (e + 3) or (len + 1)
		elseif string.sub(s, lt + 1, lt + 1) == "?" or string.sub(s, lt + 1, lt + 1) == "!" then
			local e = string.find(s, ">", lt + 2, true)
			pos = e and (e + 1) or (len + 1)
		else
			local e = string.find(s, ">", lt + 1, true)
			if not e then break end
			local inner = string.sub(s, lt + 1, e - 1)
			pos = e + 1
			if string.sub(inner, 1, 1) == "/" then
				if #stack > 1 then table.remove(stack) end
			else
				local selfClose = string.sub(inner, -1) == "/"
				if selfClose then inner = string.sub(inner, 1, -2) end
				local name, rest = string.match(inner, "^%s*([^%s/>]+)(.*)$")
				if name then
					local node = { name = LocalName(name), attr = {}, children = {}, text = "" }
					for k, _, v in string.gmatch(rest, "([%w_:%.%-]+)%s*=%s*([\"'])(.-)%2") do
						node.attr[LocalName(k)] = XmlUnescape(v)
					end
					top.children[#top.children + 1] = node
					if not selfClose then stack[#stack + 1] = node end
				end
			end
		end
	end
	return root
end

function XmlChild(node, name)
	if not node then return nil end
	for _, c in ipairs(node.children) do
		if c.name == name then return c end
	end
	return nil
end

function XmlFind(node, name)
	if not node then return nil end
	for _, c in ipairs(node.children) do
		if c.name == name then return c end
		local r = XmlFind(c, name)
		if r then return r end
	end
	return nil
end

function XmlFindAll(node, name, out)
	out = out or {}
	if not node then return out end
	for _, c in ipairs(node.children) do
		if c.name == name then out[#out + 1] = c end
		XmlFindAll(c, name, out)
	end
	return out
end

function XmlValue(node)
	if not node then return nil end
	return XmlUnescape(trim(node.text))
end

function XmlChildValue(node, path)
	for part in string.gmatch(path, "[^/]+") do
		node = XmlChild(node, part)
		if not node then return nil end
	end
	return XmlValue(node)
end

function XmlGet(node, name)
	return XmlValue(XmlFind(node, name))
end

-- Replace the text of the first <tag> element in a raw XML document (read-modify-write).
function XmlReplaceValue(xml, tag, value)
	local s = string.find(xml, "<" .. tag .. "[%s>/]")
	if not s then return xml, false end
	local gt = string.find(xml, ">", s, true)
	if not gt then return xml, false end
	local esc = XmlEscape(value)
	if string.sub(xml, gt - 1, gt - 1) == "/" then
		return string.sub(xml, 1, s - 1) .. "<" .. tag .. ">" .. esc .. "</" .. tag .. ">" .. string.sub(xml, gt + 1), true
	end
	local cs = string.find(xml, "</" .. tag .. ">", gt, true)
	if not cs then return xml, false end
	return string.sub(xml, 1, gt) .. esc .. string.sub(xml, cs), true
end
