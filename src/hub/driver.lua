--[[=============================================================================
    DirectorLink · Hikvision (the Hikvision Hub) - Control4 DriverWorks driver
    https://directorlink.io/drivers/hikvision

    Finds every Hikvision camera and NVR on the network (Hikvision SADP discovery),
    adds them to the project as "DirectorLink · Hikvision Camera" devices with one
    click, configures them with one shared login, and gives the home one
    alerts tile plus one "Camera Alert" event for all cameras.

    Copyright 2026 DirectorLink
    SPDX-License-Identifier: Apache-2.0
    Not affiliated with or endorsed by Hikvision, Control4 or Snap One.
===============================================================================]]

local TILE_PROXY = 5001
local DISCOVERY_BINDING = 6100
local SADP_GROUP, SADP_PORT = "239.255.255.250", 37020
USER_AGENT_PRODUCT = "DirectorLink-Hikvision"
CAMERA_DRIVER = "DirectorLink-Hikvision-Camera.c4z"

DISCOVERY_WINDOW_MS = 6000
ADD_SPACING_MS = 2500
CONFIGURE_DELAY_MS = 4000

--[[=============================================================================
    State
===============================================================================]]
gFound = {}          -- ip -> device found on the network (SADP or extra IPs)
gChannels = {}       -- recorder ip -> { { id, name, ip, model } }
gCameras = {}        -- camera driver device id -> state reported by that camera

local gHub = { snoozeUntil = 0 }
local gState = {
	discovering = false,
	adding = false,
	addQueue = {},
	addedCount = 0,
	tileIcon = nil,
	alertActive = false,
	effectiveAlerts = nil,
	lastAlertCamera = nil,
	alertSnapshot = nil,
	sadpBuffer = "",
	lastNewCount = 0,
	message = nil,
}
local gTargets = {}  -- ip:port -> ISAPI target (hub login) for NVRs and snapshots
gLoginFailed = {}    -- host -> true while the hub's login is refused there

--[[=============================================================================
    Login and targets
===============================================================================]]
local function Login(forRecorder)
	if forRecorder and (Properties["NVR Username"] or "") ~= "" then
		return Properties["NVR Username"], Properties["NVR Password"] or ""
	end
	return Properties["Username"] or "", Properties["Password"] or ""
end

local function TargetFor(ip, port, recorder)
	local key = ip .. ":" .. tostring(port or 80)
	local t = gTargets[key]
	if not t then
		t = NewTarget({ host = ip, port = port or 80, name = ip })
		t.onAuthChange = function(target, failed)
			gLoginFailed[target.host] = failed or nil
			if UpdateSummary then UpdateSummary() end
		end
		gTargets[key] = t
	end
	local u, p = Login(recorder)
	SetTargetCredentials(t, u, p)
	return t
end

local function SaveState()
	pcall(function()
		local cams = {}
		for id, c in pairs(gCameras) do
			cams[tostring(id)] = { name = c.name, address = c.address, port = c.port, channel = c.channel, proxyId = c.proxyId, managed = c.managed }
		end
		C4:PersistSetValue("DL_HUB", { cameras = cams, snoozeUntil = gHub.snoozeUntil })
	end)
end

local function LoadState()
	pcall(function()
		local t = C4:PersistGetValue("DL_HUB")
		if type(t) ~= "table" then return end
		gHub.snoozeUntil = tonumber(t.snoozeUntil) or 0
		for id, c in pairs(t.cameras or {}) do
			local n = tonumber(id)
			if n then
				gCameras[n] = { id = n, name = c.name, address = c.address, port = c.port, channel = c.channel,
					proxyId = c.proxyId, managed = c.managed, online = nil }
			end
		end
	end)
end

--[[=============================================================================
    Alerts (master switch for every camera)
===============================================================================]]
local UpdateTile, UpdateSummary -- forward

local function HubAlertsEnabled()
	if os.time() < (gHub.snoozeUntil or 0) then return false end
	return (Properties["Alerts"] or "On") == "On"
end

local function PushAlertsToCameras()
	local on = HubAlertsEnabled()
	for id in pairs(gCameras) do
		SendToDriver(id, "DL_HUB_ALERTS", { HUB_ID = MyDeviceId(), ENABLED = on and "1" or "0" })
	end
end

local function AlertsChanged(reason)
	local now = HubAlertsEnabled()
	SetVar("ALERTS_ENABLED", now)
	if gState.effectiveAlerts ~= nil and gState.effectiveAlerts ~= now then
		LogInfo("Alerts %s (%s)", now and "on" or "off", reason or "")
		FireEvent(now and "Alerts On" or "Alerts Off")
	end
	gState.effectiveAlerts = now
	if gState.messageTransient and reason ~= "startup" then
		gState.message = nil
		KillTimer("MESSAGE_CLEAR")
	end
	if os.time() < (gHub.snoozeUntil or 0) then
		SetTimer("SNOOZE_END", (gHub.snoozeUntil - os.time() + 1) * 1000, function() AlertsChanged("snooze ended") end)
	else
		KillTimer("SNOOZE_END")
	end
	PushAlertsToCameras()
	UpdateTile()
	UpdateSummary()
end

local function SetAlerts(on, reason)
	gHub.snoozeUntil = 0
	SaveState()
	UpdateProperty("Alerts", on and "On" or "Off")
	AlertsChanged(reason)
end

local function SnoozeAlerts(minutes, reason)
	minutes = math.max(1, math.min(1440, tonumber(minutes) or 60))
	gHub.snoozeUntil = os.time() + minutes * 60
	SaveState()
	AlertsChanged(reason or ("snooze " .. minutes .. " min"))
end

--[[=============================================================================
    Status, summary and the alerts tile
===============================================================================]]
local function CameraList()
	local list = {}
	for _, c in pairs(gCameras) do list[#list + 1] = c end
	table.sort(list, function(a, b) return tostring(a.name or "") < tostring(b.name or "") end)
	return list
end

-- Disabled cameras (Camera Enabled = No) are left out of every problem and count
local function Problems()
	local offline, login = {}, {}
	for _, c in ipairs(CameraList()) do
		if c.disabled then
			-- ignored
		elseif c.loginFailed then login[#login + 1] = c.name or ("#" .. c.id)
		elseif c.online == false then offline[#offline + 1] = c.name or ("#" .. c.id) end
	end
	return offline, login
end

-- list, cameras in use, online, disabled
local function Counts()
	local list = CameraList()
	local active, online, disabled = 0, 0, 0
	for _, c in ipairs(list) do
		if c.disabled then
			disabled = disabled + 1
		else
			active = active + 1
			if c.online then online = online + 1 end
		end
	end
	return list, active, online, disabled
end

UpdateTile = function(force)
	local icon, desc
	local offline, login = Problems()
	if gState.discovering or gState.adding then
		icon, desc = "pending", gState.adding and "Adding cameras" or "Searching for cameras"
	elseif #offline + #login > 0 then
		icon = "error"
		desc = (#login > 0) and ("Login failed: " .. table.concat(login, ", ")) or ("Offline: " .. table.concat(offline, ", "))
	elseif not HubAlertsEnabled() then
		icon = "off"
		desc = os.time() < (gHub.snoozeUntil or 0) and ("Alerts snoozed until " .. os.date("%H:%M", gHub.snoozeUntil)) or "Alerts off"
	elseif gState.alertActive then
		icon, desc = "alert", "Alert: " .. tostring(gState.lastAlertCamera or "")
	else
		icon, desc = "on", "Alerts on"
	end
	if gState.tileIcon == icon and not force then return end
	gState.tileIcon = icon
	pcall(function() C4:SendToProxy(TILE_PROXY, "ICON_CHANGED", { icon = icon, icon_description = desc }, "NOTIFY") end)
end

UpdateSummary = function()
	local list, active, online, disabled = Counts()
	SetVar("CAMERAS_TOTAL", #list)
	SetVar("CAMERAS_ONLINE", online)
	local offline, login = Problems()
	local noH264 = {}
	for _, c in ipairs(list) do
		if c.noH264 and not c.disabled then noH264[#noH264 + 1] = c.name or ("#" .. c.id) end
	end
	local text
	if #list == 0 then
		text = "No cameras yet"
	else
		text = #list .. " camera" .. (#list == 1 and "" or "s") .. " - " .. online .. " online"
		if disabled > 0 then text = text .. " - " .. disabled .. " disabled" end
		if #offline > 0 then text = text .. " - offline: " .. table.concat(offline, ", ") end
		if #login > 0 then text = text .. " - login failed: " .. table.concat(login, ", ") end
		if #noH264 > 0 then text = text .. " - no H.264 video (run Set All Sub Streams To H.264): " .. table.concat(noH264, ", ") end
	end
	UpdateProperty("Cameras", text)

	local status
	local refused = {}
	for host in pairs(gLoginFailed) do refused[#refused + 1] = host end
	table.sort(refused)
	if (Properties["Username"] or "") == "" or (Properties["Password"] or "") == "" then
		status = "Setup: enter the camera Username and Password below, then run Actions > Search Network"
	elseif #refused > 0 then
		status = "Login failed on " .. table.concat(refused, ", ") .. " - check the Username and Password (NVR Username/Password for an NVR)"
	elseif gState.message then
		status = gState.message
	elseif #list == 0 then
		status = "Run Actions > Add New Cameras to add the cameras found on the network"
	elseif #offline + #login > 0 then
		status = "Attention: " .. ((#login > 0) and ("login failed on " .. table.concat(login, ", ")) or ("offline: " .. table.concat(offline, ", ")))
	else
		status = "All cameras online - " .. (HubAlertsEnabled() and "alerts on" or (os.time() < (gHub.snoozeUntil or 0) and ("alerts snoozed until " .. os.date("%H:%M", gHub.snoozeUntil)) or "alerts off"))
	end
	UpdateProperty("Status", status)
	SetVar("ALL_ONLINE", active > 0 and online == active)
end

-- transientMs: informational messages clear themselves (and on the next alerts change)
local function SetMessage(msg, transientMs)
	gState.message = msg
	gState.messageTransient = transientMs ~= nil
	if msg and transientMs then
		SetTimer("MESSAGE_CLEAR", transientMs, function()
			gState.message = nil
			UpdateSummary()
		end)
	else
		KillTimer("MESSAGE_CLEAR")
	end
	UpdateSummary()
	UpdateTile()
end

--[[=============================================================================
    Discovery: Hikvision SADP (multicast 239.255.255.250:37020) + extra IPs
===============================================================================]]
local function IsRecorder(d)
	return (tonumber(d.digital) or 0) > 1 or (tonumber(d.analog) or 0) > 1
end

function ParseProbeMatch(xml)
	local function g(tag) return string.match(xml, "<" .. tag .. ">([^<]*)</" .. tag .. ">") end
	local ip = g("IPv4Address")
	if not ValidAddress(ip) then return nil end
	return {
		ip = trim(ip), port = tonumber(g("HttpPort") or "") or 80, model = trim(g("DeviceDescription") or ""),
		serial = g("DeviceSN") or "", mac = g("MAC") or "", firmware = g("SoftwareVersion") or "",
		analog = tonumber(g("AnalogChannelNum") or "") or 0, digital = tonumber(g("DigitalChannelNum") or "") or 0,
		activated = g("Activated") ~= "false", source = "network",
	}
end

function HandleSadpData(data)
	gState.sadpBuffer = gState.sadpBuffer .. data
	while true do
		local s = string.find(gState.sadpBuffer, "<ProbeMatch>", 1, true)
		if not s then
			if #gState.sadpBuffer > 16384 then gState.sadpBuffer = "" end
			break
		end
		local _, e = string.find(gState.sadpBuffer, "</ProbeMatch>", s, true)
		if not e then break end
		local d = ParseProbeMatch(string.sub(gState.sadpBuffer, s, e))
		gState.sadpBuffer = string.sub(gState.sadpBuffer, e + 1)
		if d and not gFound[d.ip] then
			d.recorder = IsRecorder(d)
			gFound[d.ip] = d
			LogInfo("Found %s %s at %s:%d", d.recorder and "NVR" or "camera", d.model, d.ip, d.port)
		end
	end
end

local function SendProbe()
	local uuid = string.upper(string.sub(Md5(tostring(os.time()) .. tostring(math.random())), 1, 32))
	uuid = string.sub(uuid, 1, 8) .. "-" .. string.sub(uuid, 9, 12) .. "-" .. string.sub(uuid, 13, 16) .. "-" .. string.sub(uuid, 17, 20) .. "-" .. string.sub(uuid, 21, 32)
	local probe = '<?xml version="1.0" encoding="utf-8"?><Probe><Uuid>' .. uuid .. '</Uuid><Types>inquiry</Types></Probe>'
	pcall(function() C4:SendToNetwork(DISCOVERY_BINDING, SADP_PORT, probe) end)
end

local FinishDiscovery -- forward

local function ProbeExtraIps(done)
	local list = {}
	for ip in string.gmatch(Properties["Extra Camera IPs"] or "", "[^,;%s]+") do
		if ValidAddress(ip) and not gFound[ip] then list[#list + 1] = ip end
	end
	local i = 0
	local function nextIp()
		i = i + 1
		local ip = list[i]
		if not ip then return done() end
		local host, port = string.match(ip, "^([^:]+):?(%d*)$")
		port = tonumber(port) or 80
		Isapi(TargetFor(host, port), "GET", "/ISAPI/System/deviceInfo", nil, function(code, body)
			if code == 200 then
				local info = ParseDeviceInfo(body)
				gFound[host] = { ip = host, port = port, model = info.model, serial = info.serial, firmware = info.firmware,
					recorder = info.isRecorder, deviceName = info.name, activated = true, source = "manual" }
				LogInfo("Extra IP %s: %s", host, info.model)
			else
				LogWarn("Extra IP %s did not answer as a Hikvision device (%s)", host, tostring(code))
			end
			nextIp()
		end, { timeout = 8 })
	end
	nextIp()
end

function StartDiscovery(reason)
	if gState.discovering then return end
	gState.discovering = true
	gFound = {}
	gState.sadpBuffer = ""
	LogInfo("Searching the network for Hikvision devices (%s)", reason or "")
	SetMessage("Searching the network...")
	pcall(function()
		C4:CreateNetworkConnection(DISCOVERY_BINDING, SADP_GROUP)
		C4:NetPortOptions(DISCOVERY_BINDING, SADP_PORT, "MULTICAST", {
			AUTO_CONNECT = false, MONITOR_CONNECTION = false, KEEP_CONNECTION = false,
			MIRROR_UDP_PORT = true, SUPPRESS_CONNECTION_EVENTS = true,
		})
		C4:NetConnect(DISCOVERY_BINDING, SADP_PORT, "MULTICAST")
	end)
	SetTimer("PROBE_1", 800, SendProbe)
	SetTimer("PROBE_2", 2200, SendProbe)
	SetTimer("PROBE_3", 3600, SendProbe)
	SetTimer("DISCOVERY_END", DISCOVERY_WINDOW_MS, function()
		pcall(function() C4:NetDisconnect(DISCOVERY_BINDING, SADP_PORT, "MULTICAST") end)
		ProbeExtraIps(function() FinishDiscovery() end)
	end)
end

-- Read every recorder's channel list (names and camera IPs) with the hub login
local function ReadRecorderChannels(done)
	local recorders = {}
	for _, d in pairs(gFound) do
		if d.recorder then recorders[#recorders + 1] = d end
	end
	local i = 0
	local function nextRecorder()
		i = i + 1
		local d = recorders[i]
		if not d then return done() end
		local u, p = Login(true)
		if u == "" or p == "" then return nextRecorder() end
		Isapi(TargetFor(d.ip, d.port, true), "GET", "/ISAPI/ContentMgmt/InputProxy/channels", nil, function(code, body)
			local list = {}
			if code == 200 then
				for _, ch in ipairs(XmlFindAll(XmlParse(body), "InputProxyChannel")) do
					local id = tonumber(string.match(XmlChildValue(ch, "id") or "", "%d+") or "")
					if id then
						list[#list + 1] = {
							id = id, name = XmlChildValue(ch, "name") or "",
							ip = XmlGet(ch, "ipAddress"), model = XmlGet(ch, "model") or "",
						}
					end
				end
				LogInfo("NVR %s: %d channels", d.ip, #list)
			else
				LogWarn("Could not read the channels of NVR %s (%s)", d.ip, tostring(code))
			end
			gChannels[d.ip] = list
			nextRecorder()
		end, { timeout = 15 })
	end
	nextRecorder()
end

local UpdateFoundSummary -- forward

-- Drop cameras that were deleted from the project. When Director's list of camera drivers
-- includes cameras the hub knows, it is trusted; otherwise a camera is only dropped when
-- Director no longer knows its name either.
function PruneDeleted()
	local ok, devs = pcall(function() return C4:GetDevicesByC4iName(CAMERA_DRIVER) end)
	local listed = {}
	if ok and type(devs) == "table" then
		for _, v in pairs(devs) do
			local id = tonumber(v)
			if id then listed[id] = true end
		end
	end
	local trusted = false
	for id in pairs(gCameras) do
		if listed[id] then trusted = true break end
	end
	local changed = false
	for id in pairs(gCameras) do
		if not listed[id] then
			local gone = trusted
			if not gone then
				local okName, name = pcall(function() return C4:GetDeviceDisplayName(id) end)
				gone = not okName or name == nil or name == ""
			end
			if gone then
				LogInfo("Camera device %d was removed from the project", id)
				gCameras[id] = nil
				changed = true
			end
		end
	end
	if changed then
		SaveState()
		UpdateSummary()
		UpdateFoundSummary()
	end
	return listed
end

local function InProject(address, channel)
	for _, c in pairs(gCameras) do
		if c.address == address and (tonumber(c.channel) or 1) == (tonumber(channel) or 1) then return true end
	end
	return false
end

-- Ignored Cameras: "camera IP" (also its NVR channel), "NVR IP/channel", or "NVR IP" (all its channels)
local function IgnoredCameras()
	local set = {}
	for item in string.gmatch(Properties["Ignored Cameras"] or "", "[^,;%s]+") do set[item] = true end
	return set
end

local function IsIgnored(c, set)
	return set[c.address] or set[c.address .. "/" .. tostring(c.channel or 1)] or (c.cameraIp and set[c.cameraIp]) or false
end

-- Cameras that could be added: every direct camera, plus NVR channels whose camera is not reachable directly.
-- Returns the new ones (not in the project, not ignored), every candidate, and how many were ignored.
function BuildCandidates()
	local candidates, nameByIp = {}, {}
	for nvrIp, list in pairs(gChannels) do
		for _, ch in ipairs(list) do
			if ch.ip and ch.name and not IsGenericCameraName(ch.name) then nameByIp[ch.ip] = ch.name end
		end
	end
	for ip, d in pairs(gFound) do
		if not d.recorder and d.activated ~= false then
			candidates[#candidates + 1] = { address = ip, port = d.port, channel = 1, model = d.model, nvrName = nameByIp[ip], deviceName = d.deviceName }
		end
	end
	for nvrIp, list in pairs(gChannels) do
		local nvr = gFound[nvrIp]
		for _, ch in ipairs(list) do
			if not (ch.ip and gFound[ch.ip]) then
				candidates[#candidates + 1] = { address = nvrIp, port = nvr and nvr.port or 80, channel = ch.id, model = ch.model,
					nvrName = (not IsGenericCameraName(ch.name)) and ch.name or nil, viaNvr = true, cameraIp = ch.ip }
			end
		end
	end
	local new, ignored, skip = {}, 0, IgnoredCameras()
	for _, c in ipairs(candidates) do
		if not InProject(c.address, c.channel) then
			if IsIgnored(c, skip) then ignored = ignored + 1 else new[#new + 1] = c end
		end
	end
	local function ipKey(c)
		local a, b, c3, d4 = string.match(c.address, "(%d+)%.(%d+)%.(%d+)%.(%d+)")
		return string.format("%03d%03d%03d%03d%04d", tonumber(a) or 0, tonumber(b) or 0, tonumber(c3) or 0, tonumber(d4) or 0, c.channel or 1)
	end
	table.sort(new, function(x, y) return ipKey(x) < ipKey(y) end)
	return new, candidates, ignored
end

-- "Found On Network", kept current as cameras are added, deleted or ignored
UpdateFoundSummary = function()
	if not gState.searched then return nil end
	local cams, recs, inactive = 0, 0, 0
	for _, d in pairs(gFound) do
		if d.activated == false then inactive = inactive + 1
		elseif d.recorder then recs = recs + 1 else cams = cams + 1 end
	end
	local new, _, ignored = BuildCandidates()
	local found = cams .. " camera" .. (cams == 1 and "" or "s")
	if recs > 0 then found = found .. ", " .. recs .. " NVR" .. (recs == 1 and "" or "s") end
	found = found .. " - " .. #new .. " not added yet"
	if ignored > 0 then found = found .. " - " .. ignored .. " ignored" end
	if inactive > 0 then found = found .. " - " .. inactive .. " not activated (activate with Hikvision SADP)" end
	UpdateProperty("Found On Network", found)
	return found, new, cams, recs
end

FinishDiscovery = function()
	ReadRecorderChannels(function()
		gState.discovering = false
		gState.searched = true
		PruneDeleted()
		local found, new, cams, recs = UpdateFoundSummary()
		LogInfo("Search complete: %s", found)
		if #new > 0 and #new ~= gState.lastNewCount then FireEvent("New Cameras Found") end
		gState.lastNewCount = #new
		if gState.renameAfterSearch then
			gState.renameAfterSearch = false
			return UpdateCameraNames()
		end
		if cams + recs == 0 then
			SetMessage("No Hikvision devices answered. Check that they are on the controller's network, or list them in Extra Camera IPs")
		elseif #new > 0 then
			SetMessage(#new .. " new camera" .. (#new == 1 and "" or "s") .. " found - run Actions > Add New Cameras")
		else
			SetMessage(nil)
		end
	end)
end

--[[=============================================================================
    Adding cameras to the project
===============================================================================]]
local function UniqueName(name, exceptId)
	local used = {}
	for id, c in pairs(gCameras) do
		if c.name and id ~= exceptId then used[c.name] = true end
	end
	if not used[name] then return name end
	local n = 2
	while used[name .. " " .. n] do n = n + 1 end
	return name .. " " .. n
end

-- Names that are not worth keeping: Hikvision defaults and our own "model (ip)" fallback
local function IsFallbackName(name)
	return type(name) ~= "string" or IsGenericCameraName(name) or string.find(name, "%(%d+%.%d+%.%d+%.%d+") ~= nil
end

-- Names of cameras already in the project (any camera driver), by IP.
-- Lets the hub replace another camera driver without losing the names people know.
function ExistingControl4Names()
	local byIp, ours = {}, {}
	for _, c in pairs(gCameras) do
		if c.proxyId then ours[tonumber(c.proxyId)] = true end
	end
	local ok, devs = pcall(function() return C4:GetDevicesByC4iName("camera.c4i") end)
	if not ok or type(devs) ~= "table" then return byIp end
	for _, v in pairs(devs) do
		local pid = tonumber(v)
		if pid and not ours[pid] then
			local okP, xml = pcall(function() return C4:SendUIRequest(pid, "GET_PROPERTIES", {}) end)
			local addr = okP and type(xml) == "string" and string.match(xml, "<address>([^<]*)</address>") or nil
			local okN, name = pcall(function() return C4:GetDeviceDisplayName(pid) end)
			if addr and ValidAddress(addr) and okN and not IsFallbackName(name) then
				addr = trim(addr)
				if not byIp[addr] then byIp[addr] = name end
			end
		end
	end
	return byIp
end

-- The camera's own name: its video (OSD) channel name, then its device name
local function CameraOwnName(c, cb)
	local t = TargetFor(c.address, c.port, c.viaNvr)
	local path = c.viaNvr and ("/ISAPI/ContentMgmt/InputProxy/channels/" .. c.channel) or ("/ISAPI/System/Video/inputs/channels/" .. (c.channel or 1))
	Isapi(t, "GET", path, nil, function(code, body)
		if code == 200 then
			local n = XmlGet(XmlParse(body), "name")
			if not IsFallbackName(n) then return cb(n) end
		end
		if c.viaNvr then return cb(nil) end
		Isapi(t, "GET", "/ISAPI/System/deviceInfo", nil, function(code2, body2)
			if code2 == 200 then
				local info = ParseDeviceInfo(body2)
				if not IsFallbackName(info.name) then return cb(info.name) end
			end
			cb(nil)
		end, { timeout = 8 })
	end, { timeout = 8 })
end

-- Automatic: existing Control4 name (same IP) > NVR channel name > camera's own name > model and IP
local function ResolveName(c, cb, existing)
	local mode = Properties["Camera Names"] or "Automatic"
	local fallback = ((c.model or "") ~= "" and c.model or "Camera") .. " (" .. c.address .. (c.viaNvr and (" ch" .. c.channel) or "") .. ")"
	if mode == "Model and IP" then return cb(fallback) end
	if mode == "Automatic" then
		local e = existing and not c.viaNvr and existing[c.address]
		if e then return cb(e) end
		if c.nvrName then return cb(c.nvrName) end
	end
	CameraOwnName(c, function(n) cb(n or fallback) end)
end

-- NVR channel name for a camera already in the project
local function NvrNameFor(c)
	for nvrIp, list in pairs(gChannels) do
		for _, ch in ipairs(list) do
			local match = (c.viaNvr and nvrIp == c.address and ch.id == tonumber(c.channel)) or (not c.viaNvr and ch.ip == c.address)
			if match and not IsFallbackName(ch.name) then return ch.name end
		end
	end
	return nil
end

-- Action: rename the cameras the hub added, from the best name available now
function UpdateCameraNames()
	if next(gChannels) == nil and not gState.discovering then
		gState.renameAfterSearch = true
		StartDiscovery("update names")
		return
	end
	PruneDeleted()
	local existing = ExistingControl4Names()
	local list = {}
	for _, c in pairs(gCameras) do
		if c.managed and c.address then list[#list + 1] = c end
	end
	local i, renamed = 0, 0
	local function nextCam()
		i = i + 1
		local c = list[i]
		if not c then
			SaveState()
			SetMessage("Camera names updated: " .. renamed .. " renamed", 120000)
			return
		end
		local cand = { address = c.address, port = c.port, channel = c.channel, viaNvr = c.viaNvr, model = c.model or "", nvrName = NvrNameFor(c) }
		ResolveName(cand, function(name)
			if name and not IsFallbackName(name) and name ~= c.name then
				c.name = UniqueName(name, c.id)
				renamed = renamed + 1
				LogInfo("Renaming camera %d to %s", c.id, c.name)
				ConfigureCamera(c.id, { RENAME = "1" })
			end
			nextCam()
		end, existing)
	end
	SetMessage("Updating camera names...")
	nextCam()
end

function ConfigureCamera(id, extra)
	local c = gCameras[id]
	if not c then return end
	local u, p = Login(false)
	if c.viaNvr then u, p = Login(true) end
	local params = {
		HUB_ID = MyDeviceId(), HUB_ALERTS = HubAlertsEnabled() and "1" or "0",
		ADDRESS = c.address, HTTP_PORT = c.port, CHANNEL = c.channel,
		USERNAME = u, PASSWORD = p, NAME = c.name,
	}
	for k, v in pairs(extra or {}) do params[k] = v end
	SendToDriver(id, "DL_CONFIGURE", params)
end

-- "Sub Stream To H.264" = Automatic: cameras the hub adds switch their sub stream to H.264
local function AutoH264()
	return (Properties["Sub Stream To H.264"] or "Automatic") == "Automatic"
end

local function AddNext()
	local c = table.remove(gState.addQueue, 1)
	if not c then
		gState.adding = false
		SaveState()
		UpdateFoundSummary()
		SetMessage(gState.addedCount > 0
			and ("Added " .. gState.addedCount .. " camera" .. (gState.addedCount == 1 and "" or "s") .. " - drag them to their rooms in Composer")
			or nil, 120000)
		return
	end
	local total = gState.addedCount + #gState.addQueue + 1
	SetMessage("Adding cameras: " .. (gState.addedCount + 1) .. " of " .. total .. "...")
	ResolveName(c, function(name)
		name = UniqueName(name)
		local room = nil
		pcall(function() room = C4:RoomGetId() end)
		local ok, err = pcall(function()
			local function onAdded(deviceId, info)
				deviceId = tonumber(deviceId)
				if not deviceId or deviceId == 0 then
					gState.addQueue = {}
					gState.adding = false
					SetMessage("Could not add the camera driver. Upload " .. CAMERA_DRIVER .. " with Driver > Add or Update Driver, then run Add New Cameras again")
					return
				end
				LogInfo("Added %s as device %d", name, deviceId)
				gCameras[deviceId] = { id = deviceId, name = name, address = c.address, port = c.port, channel = c.channel,
					viaNvr = c.viaNvr, managed = true, online = nil }
				gState.addedCount = gState.addedCount + 1
				SaveState()
				-- Give the new driver time to start, then send its configuration (twice, it is idempotent)
				SetTimer("CONFIGURE_" .. deviceId, CONFIGURE_DELAY_MS, function()
					ConfigureCamera(deviceId, { RENAME = "1", ALERT_ON = Properties["Default Alert On"] or "Any detection",
						FIX_SUBSTREAM = AutoH264() and "1" or nil })
				end)
				SetTimer("CONFIGURE2_" .. deviceId, CONFIGURE_DELAY_MS * 3, function()
					local cam = gCameras[deviceId]
					if cam and cam.reportedAddress ~= cam.address then
						ConfigureCamera(deviceId, { RENAME = "1", FIX_SUBSTREAM = AutoH264() and "1" or nil })
					end
				end)
				-- A camera that never answers runs an old or wrong camera driver
				SetTimer("CONFIGURE_CHECK_" .. deviceId, CONFIGURE_DELAY_MS * 6, function()
					local cam = gCameras[deviceId]
					if cam and not cam.reportedAddress then
						cam.noAnswer = true
						SetMessage("Camera '" .. tostring(cam.name) .. "' does not answer the hub. Update " .. CAMERA_DRIVER
							.. " (Driver > Add or Update Driver) to version " .. DRIVER_SEMVER .. ", delete the cameras that do not answer, and run Add New Cameras again")
					end
				end)
				UpdateSummary()
				SetTimer("ADD_NEXT", ADD_SPACING_MS, AddNext)
			end
			-- Documented forms: (driver, room, name, callback) or (driver, callback) = the hub's room
			if room then
				C4:AddDevice(CAMERA_DRIVER, room, name, onAdded)
			else
				C4:AddDevice(CAMERA_DRIVER, onAdded)
			end
		end)
		if not ok then
			gState.addQueue = {}
			gState.adding = false
			SetMessage("Adding cameras failed: " .. tostring(err))
		end
	end, gState.existingNames)
end

function AddNewCameras()
	if gState.adding then return end
	PruneDeleted()
	if (Properties["Username"] or "") == "" or (Properties["Password"] or "") == "" then
		SetMessage("Enter the camera Username and Password first")
		return
	end
	local new = BuildCandidates()
	if #new == 0 then
		SetMessage("No new cameras to add. Run Search Network first if you have not")
		return
	end
	-- Never add cameras with a login that does not work: they would be unnamed and unconfigured
	local probe = new[1]
	SetMessage("Checking the login on " .. probe.address .. "...")
	Isapi(TargetFor(probe.address, probe.port, probe.viaNvr), "GET", "/ISAPI/System/deviceInfo", nil, function(code, _, err)
		if code == 401 then
			SetMessage(nil)
			return
		elseif not code then
			SetMessage("Cannot reach " .. probe.address .. " (" .. tostring(err) .. ") - run Search Network and try again")
			return
		end
		gState.existingNames = ExistingControl4Names()
		gState.addQueue = new
		gState.addedCount = 0
		gState.adding = true
		UpdateTile()
		AddNext()
	end, { force = true, timeout = 10 })
end

--[[=============================================================================
    Messages from camera drivers
===============================================================================]]
local function FetchAlertSnapshot(c)
	if (Properties["Snapshot With Alerts"] or "Yes") ~= "Yes" or not c.address then return end
	local t = TargetFor(c.address, c.port, c.viaNvr)
	local path = "/ISAPI/Streaming/channels/" .. ((tonumber(c.channel) or 1) * 100 + 1) .. "/picture"
	Isapi(t, "GET", path, nil, function(code, body)
		if code == 200 and IsJpeg(body) then gState.alertSnapshot = body end
	end, { timeout = 10 })
end

local function AlertClear()
	gState.alertActive = false
	SetVar("ALERT_ACTIVE", false)
	UpdateTile()
end

local function CameraStatus(p)
	local id = tonumber(p.DEVICE_ID)
	if not id then return end
	local c = gCameras[id]
	if not c then
		c = { id = id, managed = false }
		gCameras[id] = c
	end
	local wasOnline = c.online
	c.name = (p.NAME and p.NAME ~= "") and p.NAME or c.name
	c.proxyId = tonumber(p.PROXY_ID) or c.proxyId
	if ValidAddress(p.ADDRESS) then
		c.address = p.ADDRESS
		c.reportedAddress = p.ADDRESS
	end
	c.port = tonumber(p.PORT) or c.port
	c.channel = tonumber(p.CHANNEL) or c.channel
	c.model = p.MODEL or c.model
	c.status = p.STATUS
	c.loginFailed = p.LOGIN_FAILED == "1"
	c.noAnswer = nil
	c.version = p.VERSION
	if p.DISABLED then c.disabled = p.DISABLED == "1" end
	if p.H264 then c.noH264 = p.H264 == "0" end
	-- A camera the hub added that lost its login (for example after its driver was reinstalled) gets it again
	if p.NEED_LOGIN == "1" and c.managed and c.address and (Properties["Password"] or "") ~= ""
		and os.time() - (c.loginSentAt or 0) > 300 then
		c.loginSentAt = os.time()
		LogInfo("Camera '%s' has no login: sending the hub's login", tostring(c.name))
		ConfigureCamera(id)
	end
	if p.VERSION and DRIVER_SEMVER ~= "dev" and p.VERSION ~= DRIVER_SEMVER and p.VERSION ~= "dev" then
		SetMessage("Camera '" .. tostring(c.name) .. "' runs camera driver " .. tostring(p.VERSION) .. "; the hub is " .. DRIVER_SEMVER
			.. ". Update " .. CAMERA_DRIVER .. " with Driver > Add or Update Driver")
	end
	if c.disabled then
		c.online = nil
	elseif p.ONLINE == "1" then c.online = true elseif p.ONLINE == "0" then c.online = false end
	if wasOnline == true and c.online == false then
		SetVar("LAST_OFFLINE_CAMERA", c.name or "")
		FireEvent("Camera Offline")
	elseif wasOnline == false and c.online == true then
		FireEvent("Camera Online")
	end
	SaveState()
	UpdateSummary()
	UpdateTile()
end

local function CameraAlert(p)
	local id = tonumber(p.DEVICE_ID)
	local c = id and gCameras[id] or {}
	local name = p.NAME or c.name or "Camera"
	gState.lastAlertCamera = name
	gState.lastAlertType = p.TYPE or ""
	gState.alertActive = true
	SetVar("ALERT_ACTIVE", true)
	SetVar("LAST_ALERT_CAMERA", name)
	SetVar("LAST_ALERT_TYPE", p.TYPE or "")
	SetVar("LAST_ALERT_TIME", p.TIME or os.date("%Y-%m-%d %H:%M:%S"))
	if c.address then FetchAlertSnapshot(c) end
	FireEvent("Camera Alert")
	UpdateTile()
	SetTimer("ALERT_CLEAR", 30000, AlertClear)
end

local function HelloCameras()
	local found = PruneDeleted()
	for id in pairs(gCameras) do found[id] = true end
	for id in pairs(found) do
		SendToDriver(id, "DL_HUB_HELLO", { HUB_ID = MyDeviceId(), HUB_ALERTS = HubAlertsEnabled() and "1" or "0" })
	end
	SaveState()
	UpdateSummary()
end

-- Control4 plays H.264 only: ask every camera to switch its sub stream (the main stream is left alone)
local function SubStreamsToH264()
	local n = 0
	for id, c in pairs(gCameras) do
		if not c.disabled then
			SendToDriver(id, "DL_FIX_SUBSTREAM", {})
			n = n + 1
		end
	end
	LogInfo("Sub stream to H.264 sent to %d cameras", n)
	SetMessage("Asked " .. n .. " camera" .. (n == 1 and "" or "s") .. " to set the sub stream to H.264 - each camera's Video line shows the result", 120000)
end

local function ApplyLoginToAll()
	local n = 0
	for id, c in pairs(gCameras) do
		if c.managed then
			ConfigureCamera(id)
			n = n + 1
		end
	end
	LogInfo("Login sent to %d cameras", n)
end

--[[=============================================================================
    Report
===============================================================================]]
local function PrintCameraList()
	local lines = { "===== Hikvision Hub - cameras =====", "Status : " .. tostring(Properties["Status"]) }
	for _, c in ipairs(CameraList()) do
		lines[#lines + 1] = string.format("%-24s %-16s ch%-3s %-8s %s%s%s", tostring(c.name), tostring(c.address), tostring(c.channel or 1),
			c.disabled and "DISABLED" or (c.online == true and "online" or (c.online == false and "OFFLINE" or "?")), c.loginFailed and "LOGIN FAILED " or "",
			c.noH264 and "NO H.264 VIDEO " or "", c.managed and "" or "(added manually)")
	end
	local new, _, ignored = BuildCandidates()
	lines[#lines + 1] = "--- on the network, not added yet (" .. #new .. ")" .. (ignored > 0 and (", " .. ignored .. " ignored") or "") .. " ---"
	for _, c in ipairs(new) do
		lines[#lines + 1] = string.format("%-16s ch%-3s %-24s %s", c.address, tostring(c.channel), tostring(c.model), c.nvrName and ("NVR name: " .. c.nvrName) or "")
	end
	for _, d in pairs(gFound) do
		if d.activated == false then lines[#lines + 1] = "NOT ACTIVATED (activate it with Hikvision SADP first): " .. d.ip .. " " .. d.model end
	end
	lines[#lines + 1] = "==================================="
	print(table.concat(lines, "\n"))
end

--[[=============================================================================
    DriverWorks entry points
===============================================================================]]
local VARIABLES = {
	{ "ALERTS_ENABLED", "1", "BOOL" },
	{ "ALERT_ACTIVE", "0", "BOOL" },
	{ "ALL_ONLINE", "0", "BOOL" },
	{ "CAMERAS_TOTAL", "0", "NUMBER" },
	{ "CAMERAS_ONLINE", "0", "NUMBER" },
	{ "LAST_ALERT_CAMERA", "", "STRING" },
	{ "LAST_ALERT_TYPE", "", "STRING" },
	{ "LAST_ALERT_TIME", "", "STRING" },
	{ "LAST_OFFLINE_CAMERA", "", "STRING" },
}

local ACTIONS = {
	Search = function() StartDiscovery("action") end,
	AddCameras = function() AddNewCameras() end,
	ApplyLogin = function() ApplyLoginToAll() end,
	UpdateNames = function() UpdateCameraNames() end,
	SubStreamsH264 = function() SubStreamsToH264() end,
	List = PrintCameraList,
}

local COMMANDS = {
	SET_ALERTS = function(p)
		local s = string.upper(p["State"] or "TOGGLE")
		if s == "ON" then SetAlerts(true, "programming")
		elseif s == "OFF" then SetAlerts(false, "programming")
		else SetAlerts(not HubAlertsEnabled(), "programming") end
	end,
	SNOOZE_ALERTS = function(p) SnoozeAlerts(p["Minutes"], "programming") end,
	SEARCH_NETWORK = function() StartDiscovery("programming") end,
	DL_CAMERA_STATUS = CameraStatus,
	DL_CAMERA_ALERT = CameraAlert,
}

function OnDriverInit()
	math.randomseed(os.time())
	AddVariables(VARIABLES)
	LoadState()
end

function OnDriverLateInit()
	ApplyLogSettings()
	pcall(function()
		local build = tostring(C4:GetDriverConfigInfo("version") or "")
		UpdateProperty("Driver Version", DRIVER_SEMVER ~= "dev" and (DRIVER_SEMVER .. " (" .. build .. ")") or build)
	end)
	AlertsChanged("startup")
	UpdateTile(true)
	HelloCameras()
	if (Properties["Username"] or "") ~= "" and (Properties["Password"] or "") ~= "" then
		SetTimer("STARTUP_SEARCH", 5000, function() StartDiscovery("startup") end)
	end
end

function OnDriverDestroyed()
	pcall(function() C4:NetDisconnect(DISCOVERY_BINDING, SADP_PORT, "MULTICAST") end)
	KillAllTimers()
end

function OnPropertyChanged(name)
	if name == "Log Level" then
		ApplyLogSettings()
	elseif name == "Alerts" then
		gHub.snoozeUntil = 0
		SaveState()
		AlertsChanged("Composer")
	elseif name == "Username" or name == "Password" or name == "NVR Username" or name == "NVR Password" then
		UpdateSummary()
		gLoginFailed = {}
		SetTimer("LOGIN_CHANGED", 2000, function()
			ApplyLoginToAll()
			StartDiscovery("login changed")
		end)
	elseif name == "Extra Camera IPs" then
		SetTimer("EXTRA_IPS", 2000, function() StartDiscovery("extra IPs") end)
	elseif name == "Ignored Cameras" then
		UpdateFoundSummary()
	elseif name == "Sub Stream To H.264" then
		if AutoH264() then SubStreamsToH264() end
	end
end

function ReceivedFromProxy(idBinding, strCommand, tParams)
	if idBinding == TILE_PROXY and strCommand == "SELECT" then
		SetAlerts(not HubAlertsEnabled(), "hub tile")
	end
end

function ReceivedFromNetwork(idBinding, nPort, strData)
	if idBinding == DISCOVERY_BINDING then HandleSadpData(strData or "") end
end

function OnConnectionStatusChanged(idBinding, nPort, strStatus)
	if idBinding == DISCOVERY_BINDING and strStatus == "ONLINE" then SendProbe() end
end

function ExecuteCommand(strCommand, tParams)
	tParams = tParams or {}
	if strCommand == "LUA_ACTION" then
		local action = ACTIONS[tParams.ACTION]
		if action then
			local ok, err = pcall(action)
			if not ok then LogError("Action %s failed: %s", tostring(tParams.ACTION), err) end
		end
		return
	end
	local cmd = COMMANDS[strCommand]
	if cmd then
		local ok, err = pcall(cmd, tParams)
		if not ok then LogError("Command %s failed: %s", strCommand, err) end
	end
end

function TestCondition(name, tParams)
	tParams = tParams or {}
	if name == "ALERTS_ENABLED" then return TestBool(HubAlertsEnabled(), tParams, "On")
	elseif name == "ALERT_ACTIVE" then return TestBool(gState.alertActive, tParams, "Active")
	elseif name == "ALL_ONLINE" then
		local _, active, online = Counts()
		return TestBool(active > 0 and online == active, tParams, "Online")
	elseif name == "LAST_ALERT_TYPE" then
		return TestEquals(gState.lastAlertType or "", tParams)
	end
	return false
end

-- Notification attachments: the camera that raised the last alert
function GetNotificationAttachmentBytes()
	if gState.alertSnapshot then return C4:Base64Encode(gState.alertSnapshot) end
	return ""
end

function GetNotificationAttachmentURL()
	for _, c in pairs(gCameras) do
		if c.name == gState.lastAlertCamera and c.address then
			local t = TargetFor(c.address, c.port, c.viaNvr)
			return TargetBaseUrl(t, true) .. "/ISAPI/Streaming/channels/" .. ((tonumber(c.channel) or 1) * 100 + 1) .. "/picture"
		end
	end
	return ""
end

function FinishedWithNotificationAttachment()
end
