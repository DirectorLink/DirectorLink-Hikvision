--[[=============================================================================
    DirectorLink · Hikvision Camera - Control4 DriverWorks driver
    https://directorlink.io/drivers/hikvision

    One camera (or one NVR channel): live video and snapshots for Navigators,
    real-time ISAPI events, alerts, touchscreen controls (Extras) and commands.
    Works on its own, or managed by the Hikvision Hub driver which discovers the
    cameras, adds them to the project and configures them with one login.

    Copyright 2026 DirectorLink
    SPDX-License-Identifier: Apache-2.0
    Not affiliated with or endorsed by Hikvision, Control4 or Snap One.
===============================================================================]]

local CAMERA_PROXY = 5001
USER_AGENT_PRODUCT = "DirectorLink-Hikvision-Camera"

-- Intervals (globals so they can be tuned from the Lua command window)
HEALTH_INTERVAL_MS = 60000
WATCHDOG_INTERVAL_MS = 30000
STREAM_SILENCE_LIMIT_S = 120
STREAM_CONNECT_TIMEOUT_MS = 15000
REFRESH_RETRY_MS = 60000

local ALERT_STREAM_PATHS = { "/ISAPI/Event/notification/alertStream", "/Event/notification/alertStream" }

--[[=============================================================================
    State
===============================================================================]]
gCam = NewTarget({ name = "camera" })

local gCfg = {
	host = "",
	user = "",
	pass = "",
	https = false,
	httpPort = 80,
	httpsPort = 443,
	rtspPort = 554,
	name = "",            -- friendly name (from the hub, else the camera's own name)
	hubId = nil,          -- device id of the Hikvision Hub managing this camera
	hubAlerts = true,     -- the hub's master alerts switch
	snoozeUntil = 0,      -- os.time() until which alerts are snoozed
}

local gInfo = {
	streams = {},
	isRecorder = false,
	model = "",
	firmware = "",
	deviceName = "",
	ptzPanTilt = false,
	ptzZoom = false,
	snapshotBase = "ISAPI/Streaming/channels/",
	centerEvents = {},
	otherEvents = {},
	dayNight = nil,
	lightSupported = false,
	lightMode = nil,
	notIsapi = false,
	snapshotMainOnly = false,
}

local gState = {
	online = nil,
	healthFails = 0,
	needRefresh = true,
	refreshGen = 0,
	refreshing = false,
	motionEnabled = nil,
	effectiveAlerts = nil,
	alertActive = false,
	lastAlert = "",
	eventSnapshot = nil,
	lastSnapshotAt = 0,
	attention = {},
	proxyWriteFailed = false,
	lastHubReport = nil,
}

--[[=============================================================================
    Connection settings
    Address, ports and login are edited on Control4's camera Properties page
    (the camera proxy), like every Control4 camera; the hub fills them in for
    the cameras it adds. That page never shows the login back, so the driver
    keeps its own copy (the password encrypted). Camera Enabled and Channel are
    the driver's own properties.
===============================================================================]]
local function Channel()
	return tonumber(Properties["Channel"]) or 1
end

local function StreamId(n)
	return Channel() * 100 + n
end

local function CameraEnabled()
	return (Properties["Camera Enabled"] or "Yes") == "Yes"
end

-- Settings -> the ISAPI target the driver uses
local function ApplyConnection()
	gCam.host = gCfg.host or ""
	gCam.https = gCfg.https == true
	gCam.port = gCam.https and gCfg.httpsPort or gCfg.httpPort
	SetTargetCredentials(gCam, gCfg.user or "", gCfg.pass or "")
end

local function HasLogin()
	return (gCfg.user or "") ~= "" and (gCfg.pass or "") ~= ""
end

local function SaveCfg()
	pcall(function()
		C4:PersistSetValue("DL_CFG", {
			host = gCfg.host, port = gCfg.httpPort, httpsPort = gCfg.httpsPort, https = gCfg.https, rtspPort = gCfg.rtspPort,
			user = gCfg.user, name = gCfg.name, hubId = gCfg.hubId, hubAlerts = gCfg.hubAlerts, snoozeUntil = gCfg.snoozeUntil,
			h264Pending = gCfg.h264Pending,
		})
		-- Director refuses to encrypt an empty value
		if (gCfg.pass or "") ~= "" then
			C4:PersistSetValue("DL_PASS", gCfg.pass, true)
		else
			C4:PersistDeleteValue("DL_PASS")
		end
	end)
end

local function LoadCfg()
	pcall(function()
		local t = C4:PersistGetValue("DL_CFG")
		if type(t) == "table" then
			gCfg.host = ValidAddress(t.host) and trim(t.host) or ""
			gCfg.httpPort = tonumber(t.port) or 80
			gCfg.httpsPort = tonumber(t.httpsPort) or 443
			gCfg.https = t.https == true
			gCfg.rtspPort = tonumber(t.rtspPort) or 554
			gCfg.user = t.user or ""
			gCfg.name = t.name or ""
			gCfg.hubId = tonumber(t.hubId)
			gCfg.hubAlerts = (t.hubAlerts ~= false)
			gCfg.snoozeUntil = tonumber(t.snoozeUntil) or 0
			gCfg.h264Pending = t.h264Pending == true
		end
		local p = C4:PersistGetValue("DL_PASS", true)
		if type(p) == "string" then gCfg.pass = p end
	end)
end

-- Read the Control4 camera page (credentials come masked)
local function ReadProxyProperties()
	local pid = ProxyId()
	if not pid then return nil end
	local ok, xml = pcall(function() return C4:SendUIRequest(pid, "GET_PROPERTIES", {}) end)
	if not ok or type(xml) ~= "string" or not string.find(xml, "camera_properties", 1, true) then return nil end
	local cp = XmlFind(XmlParse(xml), "camera_properties")
	if not cp then return nil end
	local function v(name) return XmlChildValue(cp, name) end
	return {
		address = v("address"), httpPort = tonumber(v("http_port") or ""), httpsPort = tonumber(v("https_port") or ""),
		rtspPort = tonumber(v("rtsp_port") or ""), useHttps = v("use_https"),
		authRequired = v("authentication_required"), authType = v("authentication_type"),
		username = v("username"), password = v("password"),
	}
end

-- The camera page is the place to edit: take its address, ports and HTTPS setting
-- (and the login, if the page shows it). Returns true when something changed.
local function SyncFromCameraPage()
	local p = ReadProxyProperties()
	if not p then return false end
	local changed = false
	local function set(field, value)
		if value ~= nil and gCfg[field] ~= value then
			gCfg[field] = value
			changed = true
		end
	end
	if ValidAddress(p.address) then set("host", trim(p.address)) end
	set("httpPort", p.httpPort)
	set("httpsPort", p.httpsPort)
	set("rtspPort", p.rtspPort)
	if p.useHttps and p.useHttps ~= "" then set("https", toboolean(p.useHttps)) end
	if p.username and p.username ~= "" and not IsMasked(p.username) then set("user", p.username) end
	if p.password and p.password ~= "" and not IsMasked(p.password) then set("pass", MaybeBase64Decode(p.password)) end
	if changed then SaveCfg() end
	return changed
end

--[[=============================================================================
    Status, attention and the hub link
===============================================================================]]
local gStream -- forward
local Refresh, Stream_Start, Stream_Stop, UpdateExtras, ReportToHub, SetSubStreamH264 -- forward

local function CameraName()
	if gCfg.name ~= "" then return gCfg.name end
	if gInfo.deviceName ~= "" and not IsGenericCameraName(gInfo.deviceName) then return gInfo.deviceName end
	if gInfo.model ~= "" then return gInfo.model .. " (" .. gCam.host .. ")" end
	return "Camera " .. (gCam.host ~= "" and gCam.host or "")
end

local ATTENTION_ORDER = { "login", "channel", "proxy", "video", "snapshot", "rtsp", "events", "auth" }

local function SetAttention(key, text, force)
	if gState.attention[key] == text and not force then return end
	gState.attention[key] = text
	local items = {}
	for _, k in ipairs(ATTENTION_ORDER) do
		if gState.attention[k] then items[#items + 1] = gState.attention[k] end
	end
	UpdateProperty("Attention", table.concat(items, "  |  "))
	pcall(function() C4:SetPropertyAttribs("Attention", #items > 0 and 0 or 1) end)
end

local function AlertsDescription()
	if os.time() < (gCfg.snoozeUntil or 0) then
		return "alerts snoozed until " .. os.date("%H:%M", gCfg.snoozeUntil)
	end
	if not gCfg.hubAlerts then return "alerts off (hub)" end
	if (Properties["Alerts"] or "On") ~= "On" then return "alerts off" end
	return "alerts on"
end

function UpdateStatus()
	local s
	if not CameraEnabled() then
		s = "Disabled - no events, alerts or health checks (set Camera Enabled to Yes to resume)"
	elseif not ValidAddress(gCam.host) then
		s = "Setup: enter the Address, Username and Password on the camera's Properties page"
	elseif not HasLogin() then
		s = gCfg.hubId and "Waiting for the camera login from the Hikvision Hub (or enter it on the camera's Properties page)"
			or "Setup: enter the Username and Password on the camera's Properties page"
	elseif gCam.authFailed then
		s = "Login failed on " .. gCam.host .. " - check the Username and Password (on the hub, or the camera's Properties page)"
	elseif gInfo.notIsapi then
		s = "No Hikvision camera answers at " .. HostPort(gCam.host, gCam.port, gCam.https and 443 or 80)
	elseif gState.online == false and gState.channelOffline then
		s = "Offline - the camera on NVR channel " .. Channel() .. " is not connected to the NVR"
	elseif gState.online == false then
		s = "Offline - cannot reach " .. gCam.host
	elseif gState.online == nil or gState.refreshing then
		s = "Connecting to " .. gCam.host .. "..."
	else
		local ev = (gStream and gStream.connected) and "events live" or "events reconnecting"
		if (Properties["Event Monitoring"] or "On") ~= "On" then ev = "events off" end
		s = "Online - " .. ev .. " - " .. AlertsDescription()
	end
	UpdateProperty("Status", s)
	if ReportToHub then ReportToHub() end
end

--[[=============================================================================
    Write the Control4 camera page (camera proxy) so Navigators can stream.
    Uses the same commands Composer sends to the proxy, then reads back to verify.
===============================================================================]]
local function WriteProxySettings()
	local pid = ProxyId()
	if not pid or not ValidAddress(gCam.host) then return end
	local function cmd(c, p) pcall(function() C4:SendToDevice(pid, c, p, true, false) end) end
	local function notify(c, p) pcall(function() C4:SendToProxy(CAMERA_PROXY, c, p, "NOTIFY") end) end
	gState.pageWrittenAt = os.time()
	cmd("SET_ADDRESS", { ADDRESS = gCam.host })
	cmd("SET_HTTP_PORT", { PORT = tostring(gCfg.httpPort) })
	cmd("SET_RTSP_PORT", { PORT = tostring(gCfg.rtspPort) })
	cmd("SET_AUTHENTICATION_REQUIRED", { REQUIRED = "True" })
	cmd("SET_AUTHENTICATION_TYPE", { TYPE = "DIGEST" })
	if gCam.user ~= "" then
		cmd("SET_USERNAME", { USERNAME = gCam.user })
		cmd("SET_PASSWORD", { PASSWORD = gCam.pass })
	end
	-- Documented notifications as a second path for address and ports
	notify("ADDRESS_CHANGED", { ADDRESS = gCam.host })
	notify("HTTP_PORT_CHANGED", { PORT = tostring(gCfg.httpPort) })
	notify("HTTPS_PORT_CHANGED", { PORT = tostring(gCfg.httpsPort) })
	notify("RTSP_PORT_CHANGED", { PORT = tostring(gCfg.rtspPort) })
	SetTimer("PROXY_VERIFY", 3000, function()
		local p = ReadProxyProperties()
		if not p then return end
		local ok = (trim(p.address or "") == gCam.host) and string.upper(p.authType or "") == "DIGEST"
			and toboolean(p.authRequired)
		gState.proxyWriteFailed = not ok
		if ok then
			LogInfo("Camera page updated (%s, Digest)", gCam.host)
			SetAttention("proxy", nil)
		else
			LogWarn("Camera page shows address=%s auth=%s required=%s", p.address, p.authType, p.authRequired)
			SetAttention("proxy", "Open the camera's Properties page and set Address " .. gCam.host .. ", Authentication Required, type DIGEST, and the login")
		end
	end)
end

--[[=============================================================================
    Alerts
    Detection events always fire (for automation). The "Alert" event and
    notifications fire only when alerts are on for this camera and on the hub,
    not snoozed, and the detection matches "Alert On".
===============================================================================]]
local ALERT_FILTERS = {
	["Any detection"] = { motion = true, person = true, vehicle = true, security = true },
	["People and vehicles"] = { person = true, vehicle = true, security = true },
	["People only"] = { person = true, security = true },
}

local function AlertsEnabled()
	if os.time() < (gCfg.snoozeUntil or 0) then return false end
	return (Properties["Alerts"] or "On") == "On" and gCfg.hubAlerts ~= false
end

-- Fire Alerts On/Off when the effective state changes, and refresh everything that shows it
local function AlertsChanged(reason)
	local now = AlertsEnabled()
	SetVar("ALERTS_ENABLED", now)
	if gState.effectiveAlerts ~= nil and gState.effectiveAlerts ~= now then
		LogInfo("Alerts %s (%s)", now and "on" or "off", reason or "")
		FireEvent(now and "Alerts On" or "Alerts Off")
	end
	gState.effectiveAlerts = now
	if os.time() < (gCfg.snoozeUntil or 0) then
		SetTimer("SNOOZE_END", (gCfg.snoozeUntil - os.time() + 1) * 1000, function() AlertsChanged("snooze ended") end)
	else
		KillTimer("SNOOZE_END")
	end
	if UpdateExtras then UpdateExtras() end
	UpdateStatus()
end

local function SetAlerts(on, reason)
	gCfg.snoozeUntil = 0
	SaveCfg()
	UpdateProperty("Alerts", on and "On" or "Off")
	AlertsChanged(reason)
end

local function SnoozeAlerts(minutes, reason)
	minutes = math.max(1, math.min(1440, tonumber(minutes) or 60))
	gCfg.snoozeUntil = os.time() + minutes * 60
	SaveCfg()
	AlertsChanged(reason or ("snooze " .. minutes .. " min"))
end

--[[=============================================================================
    Detections
===============================================================================]]
local DETECTIONS = {
	motion         = { label = "Motion", var = "MOTION", contact = 101, event = "Motion Detected", endEvent = "Motion Ended", class = "motion" },
	person         = { label = "Person", var = "PERSON", contact = 102, event = "Person Detected", class = "person" },
	vehicle        = { label = "Vehicle", var = "VEHICLE", contact = 103, event = "Vehicle Detected", class = "vehicle" },
	linedetection  = { label = "Line Crossing", var = "LINE_CROSSING", contact = 104, event = "Line Crossing", class = "motion" },
	fielddetection = { label = "Intrusion", var = "INTRUSION", contact = 105, event = "Intrusion Detected", class = "motion" },
	regionentrance = { label = "Region Entrance", event = "Region Entrance", class = "motion" },
	regionexiting  = { label = "Region Exiting", event = "Region Exiting", class = "motion" },
	tamper         = { label = "Tamper", var = "TAMPER", contact = 106, event = "Tamper Detected", class = "security" },
	io             = { label = "Alarm Input", var = "ALARM_INPUT", contact = 107, event = "Alarm Input Active", endEvent = "Alarm Input Inactive", endsOnInactive = true, class = "security" },
	scenechange    = { label = "Scene Change", event = "Scene Change Detected", class = "security" },
	face           = { label = "Face", event = "Face Detected", class = "person" },
	pir            = { label = "PIR", event = "PIR Alarm", class = "motion" },
	objectleft     = { label = "Object Left", event = "Object Left Behind", class = "motion" },
	objectremoved  = { label = "Object Removed", event = "Object Removed", class = "motion" },
}

local EVENT_TYPE_MAP = {
	vmd = "motion", motiondetection = "motion", vmdhumanvehicle = "motion",
	linedetection = "linedetection", fielddetection = "fielddetection",
	regionentrance = "regionentrance", regionexiting = "regionexiting",
	tamperdetection = "tamper", shelteralarm = "tamper",
	io = "io", scenechangedetection = "scenechange",
	facedetection = "face", facesnap = "face", pir = "pir",
	unattendedbaggage = "objectleft", attendedbaggage = "objectremoved",
	-- Other Hikvision detections go to the nearest one
	loitering = "fielddetection", group = "person", peoplegathering = "person", rapidmove = "motion",
	parking = "vehicle", vehicledetection = "vehicle", anpr = "vehicle", defocus = "tamper",
}

-- DirectorLink camera agreement v1: LAST_ALERT only ever carries these labels
local ALERT_LABELS = {
	["Person"] = true, ["Vehicle"] = true, ["Face"] = true, ["Motion"] = true, ["Line Crossing"] = true,
	["Intrusion"] = true, ["Region Entrance"] = true, ["Region Exiting"] = true, ["Tamper"] = true,
	["Scene Change"] = true, ["Object Left"] = true, ["Object Removed"] = true, ["Alarm Input"] = true,
	["PIR"] = true, ["Animal"] = true, ["Package"] = true, ["License Plate"] = true,
}
-- Event types and detection targets that have a more precise label than their detection
local EVENT_ALERT_LABEL = { anpr = "License Plate" }
local TARGET_ALERT_LABEL = {
	animal = "Animal", animals = "Animal", pet = "Animal", dog = "Animal", cat = "Animal",
	package = "Package", parcel = "Package", plate = "License Plate", licenseplate = "License Plate",
}

local function AlertLabel(label)
	if ALERT_LABELS[label] then return label end
	return "Motion" -- the nearest label for anything unknown
end

local function TargetAlertLabel(target)
	for word in string.gmatch(target or "", "%a+") do
		local label = TARGET_ALERT_LABEL[word]
		if label then return label end
	end
	return nil
end

local ALERT_CONTACT = 100
local CONTACT_BINDINGS = { [ALERT_CONTACT] = "alert" }
for key, d in pairs(DETECTIONS) do
	if d.contact then CONTACT_BINDINGS[d.contact] = key end
end

local gDet = {}

local function ContactClosed(active)
	local closedWhenActive = (Properties["Contact State When Active"] or "Closed") == "Closed"
	if active then return closedWhenActive end
	return not closedWhenActive
end

local function SendContact(binding, active, initial)
	local closed = ContactClosed(active)
	local cmd
	if initial then cmd = closed and "STATE_CLOSED" or "STATE_OPENED" else cmd = closed and "CLOSED" or "OPENED" end
	pcall(function() C4:SendToProxy(binding, cmd, {}, "NOTIFY") end)
end

local function HoldSeconds()
	return tonumber(Properties["Hold Time (s)"]) or 10
end

local function ContactActive(binding)
	local key = CONTACT_BINDINGS[binding]
	if key == "alert" then return gState.alertActive end
	return gDet[key] ~= nil and gDet[key].active == true
end

local function AlertEnd()
	KillTimer("ALERT_HOLD")
	if not gState.alertActive then return end
	gState.alertActive = false
	SetVar("ALERT_ACTIVE", false)
	SendContact(ALERT_CONTACT, false)
	UpdateStatus()
end

local CaptureEventSnapshot -- forward

local function TriggerAlert(d, label)
	if not AlertsEnabled() then return end
	local filter = ALERT_FILTERS[Properties["Alert On"] or "Any detection"] or ALERT_FILTERS["Any detection"]
	if not filter[d.class] then return end
	if not gState.alertActive then
		label = AlertLabel(label or d.label)
		gState.alertActive = true
		gState.lastAlert = label
		local stamp = os.date("%Y-%m-%d %H:%M:%S")
		SetVar("ALERT_ACTIVE", true)
		SetVar("LAST_ALERT", label)
		SetVar("LAST_ALERT_TIME", stamp)
		SendContact(ALERT_CONTACT, true)
		if CaptureEventSnapshot then CaptureEventSnapshot() end
		FireEvent("Alert")
		if (Properties["Record Alerts In History"] or "Yes") == "Yes" then
			pcall(function() C4:RecordHistory("Info", label .. " detected", "Cameras", CameraName(), { camera = CameraName(), detection = label }) end)
		end
		if gCfg.hubId then
			SendToDriver(gCfg.hubId, "DL_CAMERA_ALERT", { DEVICE_ID = MyDeviceId(), PROXY_ID = ProxyId(), NAME = CameraName(), TYPE = label, TIME = stamp })
		end
		UpdateStatus()
	end
	SetTimer("ALERT_HOLD", HoldSeconds() * 1000, AlertEnd)
end

local function DetectionEnd(key)
	local d = DETECTIONS[key]
	local st = gDet[key]
	KillTimer("DET_" .. key)
	if not st or not st.active then return end
	st.active = false
	LogDebug("%s ended", d.label)
	if d.var then SetVar(d.var, false) end
	if d.contact then SendContact(d.contact, false) end
	if d.endEvent then FireEvent(d.endEvent) end
end

local function DetectionPulse(key, alertLabel)
	local d = DETECTIONS[key]
	if not d then return end
	local st = gDet[key]
	if not st then
		st = { active = false }
		gDet[key] = st
	end
	if not st.active then
		st.active = true
		LogDebug("%s started", d.label)
		SetVar("LAST_DETECTION", d.label)
		if d.var then SetVar(d.var, true) end
		if d.contact then SendContact(d.contact, true) end
		FireEvent(d.event)
	end
	TriggerAlert(d, alertLabel)
	SetTimer("DET_" .. key, HoldSeconds() * 1000, function() DetectionEnd(key) end)
end

local function EndAllDetections()
	for key in pairs(DETECTIONS) do DetectionEnd(key) end
	AlertEnd()
end

local function IsDetectionActive(label)
	for key, d in pairs(DETECTIONS) do
		if d.label == label then return gDet[key] ~= nil and gDet[key].active == true end
	end
	return false
end

local function ChannelMatches(ch, version)
	if ch == nil then return true end
	local want = Channel()
	if ch == want then return true end
	-- v1.0 (PSIA) NVR alerts number IP channels from 33
	if version == "1.0" and ch > 32 and (ch - 32) == want then return true end
	return false
end

function HandleAlert(xml)
	if not CameraEnabled() then return end
	xml = string.gsub(xml, "&([^;%s<]*;?)", function(m)
		if string.match(m, "^#?%w+;$") then return "&" .. m end
		return "&amp;" .. m
	end)
	local a = XmlFind(XmlParse(xml), "EventNotificationAlert")
	if not a then return end
	local etype = string.lower(XmlChildValue(a, "eventType") or "")
	local state = string.lower(XmlChildValue(a, "eventState") or "active")
	if etype == "duration" then
		local rel = XmlGet(a, "relationEvent")
		if rel then etype = string.lower(rel) end
		state = "active"
	end
	if etype == "videoloss" then
		if state == "active" then LogWarn("Camera reports video loss") end
		return -- inactive videoloss is the stream heartbeat
	end
	local ch = tonumber(XmlChildValue(a, "channelID") or "") or tonumber(XmlChildValue(a, "dynChannelID") or "")
	local ioPort = XmlChildValue(a, "inputIOPortID") or XmlChildValue(a, "dynInputIOPortID")
	if not ioPort and not ChannelMatches(ch, a.attr.version) then return end

	local target = XmlGet(a, "detectionTarget") or XmlChildValue(a, "targetType")
	target = target and string.lower(target) or nil
	LogDebug("Alert: type=%s state=%s channel=%s target=%s", etype, state, ch, target)

	local key = EVENT_TYPE_MAP[etype]
	if key then
		if state == "active" then
			DetectionPulse(key, TargetAlertLabel(target) or EVENT_ALERT_LABEL[etype])
		elseif DETECTIONS[key].endsOnInactive then
			DetectionEnd(key)
		end
	else
		LogInfo("Unhandled event type '%s' (%s)", etype, state)
	end
	if state == "active" and target then
		if string.find(target, "human", 1, true) or string.find(target, "person", 1, true) or string.find(target, "people", 1, true) then
			DetectionPulse("person")
		end
		if string.find(target, "vehicle", 1, true) or string.find(target, "car", 1, true) then
			DetectionPulse("vehicle")
		end
	end
end

--[[=============================================================================
    Online state & health check
===============================================================================]]
local function SetOnline(on)
	if not CameraEnabled() then return end
	if on and gState.channelOffline then on = false end -- the NVR answers, its camera does not
	if gState.online == on then return end
	local prev = gState.online
	gState.online = on
	SetVar("ONLINE", on)
	if on then gState.healthFails = 0 else EndAllDetections() end
	if prev ~= nil then FireEvent(on and "Camera Online" or "Camera Offline") end
	UpdateStatus()
end

-- An NVR channel can be offline while the NVR itself answers: ask the NVR about the channel
local function SetChannelOffline(off)
	if gState.channelOffline == off then return end
	local wasOffline = gState.channelOffline == true
	gState.channelOffline = off
	if off then
		LogWarn("The camera on NVR channel %d is offline", Channel())
		SetAttention("channel", "The camera on NVR channel " .. Channel() .. " is offline (not connected to the NVR). If it is gone for good, set Camera Enabled to No")
		SetAttention("snapshot", nil)
	else
		SetAttention("channel", nil)
		if wasOffline then
			LogInfo("The camera on NVR channel %d is back", Channel())
			SetTimer("REFRESH", 2000, function() Refresh() end) -- streams, snapshots and anything that waited
		end
	end
end

local function CheckChannel(done)
	Isapi(gCam, "GET", "/ISAPI/ContentMgmt/InputProxy/channels/status", nil, function(code, body, err)
		if code == 200 then
			local state
			for _, st in ipairs(XmlFindAll(XmlParse(body), "InputProxyChannelStatus")) do
				if tonumber(string.match(XmlChildValue(st, "id") or "", "%d+") or "") == Channel() then
					local v = XmlChildValue(st, "online")
					if v then state = toboolean(v) end
				end
			end
			SetChannelOffline(state == false)
			SetOnline(true)
		elseif code then
			-- The NVR answers but gives no channel status (older firmware): count it as online
			SetChannelOffline(false)
			SetOnline(true)
		else
			gState.healthFails = gState.healthFails + 1
			LogDebug("NVR channel check failed (%d): %s", gState.healthFails, err)
			if gState.healthFails >= 2 then SetOnline(false) end
		end
		if done then done() end
	end, { timeout = 10 })
end

local function HealthCheck()
	if not CameraEnabled() or not ValidAddress(gCam.host) then return end
	if gInfo.isRecorder and HasLogin() and not gCam.authFailed then
		CheckChannel()
		return
	end
	if gStream.connected and (os.time() - gStream.lastData) < STREAM_SILENCE_LIMIT_S then
		SetOnline(true)
		return
	end
	-- Unauthenticated probe: any HTTP answer (even 401) proves the camera is up and costs no login
	Isapi(gCam, "GET", "/ISAPI/System/deviceInfo", nil, function(code, _, err)
		if code then
			SetOnline(true)
			if gState.needRefresh and not gCam.authFailed then Refresh() end
		else
			gState.healthFails = gState.healthFails + 1
			LogDebug("Health check failed (%d): %s", gState.healthFails, err)
			if gState.healthFails >= 2 then SetOnline(false) end
		end
	end, { noAuth = true, timeout = 10 })
end

--[[=============================================================================
    Event stream: ISAPI alertStream over a raw TCP connection
===============================================================================]]
gStream = { gen = 0, client = nil, connected = false, lastData = 0, fails = 0, pathIndex = 1, auth = NewAuth(), authTries = 0 }

local function EventsEnabled()
	return (Properties["Event Monitoring"] or "On") == "On"
end

Stream_Stop = function()
	gStream.gen = gStream.gen + 1
	KillTimer("STREAM_RECONNECT")
	KillTimer("STREAM_CONNECT_TIMEOUT")
	if gStream.client then
		local c = gStream.client
		gStream.client = nil
		pcall(function() c:Close() end)
	end
	local was = gStream.connected
	gStream.connected = false
	if was then UpdateStatus() end
end

local function Stream_Reconnect(delayMs)
	Stream_Stop()
	SetTimer("STREAM_RECONNECT", math.max(delayMs or 0, 100), function() Stream_Start() end)
end

local function Stream_Retry(reason)
	gStream.fails = gStream.fails + 1
	local delay = math.min(60, 5 * (2 ^ math.min(gStream.fails - 1, 4)))
	LogDebug("Event stream: %s (retry %d in %ds)", reason, gStream.fails, delay)
	Stream_Reconnect(delay * 1000)
end

-- Incremental HTTP chunked transfer decoder
function Dechunk(st, data)
	st.cbuf = st.cbuf .. data
	local out = {}
	while true do
		if st.need == nil then
			local e = string.find(st.cbuf, "\r\n", 1, true)
			if not e then break end
			local line = string.sub(st.cbuf, 1, e - 1)
			st.cbuf = string.sub(st.cbuf, e + 2)
			if line ~= "" then
				local size = tonumber(string.match(line, "^%s*(%x+)") or "", 16)
				if size == 0 then st.ended = true elseif size then st.need = size end
			end
		else
			if #st.cbuf == 0 then break end
			local take = math.min(st.need, #st.cbuf)
			out[#out + 1] = string.sub(st.cbuf, 1, take)
			st.cbuf = string.sub(st.cbuf, take + 1)
			st.need = st.need - take
			if st.need == 0 then st.need = nil end
		end
	end
	return table.concat(out)
end

-- Extract complete <EventNotificationAlert> documents from the multipart body
function Stream_Feed(st, data, onAlert)
	st.xbuf = st.xbuf .. data
	while true do
		local s = string.find(st.xbuf, "<EventNotificationAlert", 1, true)
		if not s then
			if #st.xbuf > 64 then st.xbuf = string.sub(st.xbuf, -64) end
			break
		end
		local _, e2 = string.find(st.xbuf, "</EventNotificationAlert>", s, true)
		if not e2 then
			if s > 1 then st.xbuf = string.sub(st.xbuf, s) end
			if #st.xbuf > 262144 then st.xbuf = "" end
			break
		end
		local xml = string.sub(st.xbuf, s, e2)
		st.xbuf = string.sub(st.xbuf, e2 + 1)
		local ok, err = pcall(onAlert, xml)
		if not ok then LogError("Alert handling failed: %s", err) end
	end
end

local function Stream_ParseHeaders(data)
	local status = tonumber(string.match(data, "^HTTP/%d%.%d%s+(%d+)") or "")
	local headers = {}
	for k, v in string.gmatch(data, "\r\n([^:\r\n]+):[ \t]*([^\r\n]*)") do
		local lk = string.lower(k)
		if headers[lk] == nil then headers[lk] = v
		elseif type(headers[lk]) == "table" then table.insert(headers[lk], v)
		else headers[lk] = { headers[lk], v } end
	end
	return status, headers
end

local function Stream_OnRead(client, data, gen)
	gStream.lastData = os.time()
	if not gStream.inBody then
		local status, headers = Stream_ParseHeaders(data)
		if status == 200 then
			KillTimer("STREAM_CONNECT_TIMEOUT")
			gStream.inBody = true
			gStream.connected = true
			gStream.fails = 0
			gStream.authTries = 0
			gStream.chunked = string.find(string.lower(tostring(headers["transfer-encoding"] or "")), "chunked", 1, true) ~= nil
			if gStream.sentAuth then SetTargetAuthFailed(gCam, false) end
			LogInfo("Event stream connected")
			SetOnline(true)
			UpdateStatus()
			client:ReadUpTo(65536)
		elseif status == 401 then
			gStream.authTries = gStream.authTries + 1
			local parsed = ParseChallenge(gStream.auth, headers["www-authenticate"])
			if parsed and (gStream.authTries == 1 or (gStream.authTries == 2 and gStream.auth.stale)) then
				Stream_Reconnect(100)
			else
				Stream_Stop()
				SetTargetAuthFailed(gCam, true)
			end
		elseif status == 404 and gStream.pathIndex < #ALERT_STREAM_PATHS then
			gStream.pathIndex = gStream.pathIndex + 1
			Stream_Reconnect(100)
		else
			Stream_Retry("HTTP " .. tostring(status))
		end
		return
	end
	local payload = data
	if gStream.chunked then payload = Dechunk(gStream.cstate, data) end
	if payload ~= "" then Stream_Feed(gStream, payload, HandleAlert) end
	if gen == gStream.gen then client:ReadUpTo(65536) end
end

Stream_Start = function()
	Stream_Stop()
	if not CameraEnabled() or not EventsEnabled() or not ValidAddress(gCam.host) or not HasLogin() or gCam.authFailed or gInfo.notIsapi then
		UpdateStatus()
		return
	end
	local gen = gStream.gen
	local port = gCfg.httpPort or 80 -- the event stream is plain HTTP, also when Use HTTPS is on
	local path = ALERT_STREAM_PATHS[gStream.pathIndex] or ALERT_STREAM_PATHS[1]
	gStream.inBody = false
	gStream.chunked = false
	gStream.cstate = { cbuf = "", need = nil }
	gStream.xbuf = ""
	gStream.lastData = os.time()
	local cli = C4:CreateTCPClient()
	gStream.client = cli
	cli:OnConnect(function(client)
		if gen ~= gStream.gen then return end
		local req = "GET " .. path .. " HTTP/1.1\r\nHost: " .. HostPort(gCam.host, port, 80) ..
			"\r\nUser-Agent: " .. UserAgent() .. "\r\nAccept: */*\r\nConnection: keep-alive\r\n"
		local a = AuthHeader(gStream.auth, "GET", path, gCam.user, gCam.pass)
		gStream.sentAuth = (a ~= nil)
		if a then req = req .. "Authorization: " .. a .. "\r\n" end
		client:Write(req .. "\r\n")
		client:ReadUntil("\r\n\r\n")
	end)
	cli:OnRead(function(client, data)
		if gen ~= gStream.gen then return end
		local ok, err = pcall(Stream_OnRead, client, data, gen)
		if not ok then
			LogError("Event stream error: %s", err)
			Stream_Retry("parse error")
		end
	end)
	cli:OnDisconnect(function()
		if gen ~= gStream.gen then return end
		Stream_Retry("disconnected")
	end)
	cli:OnError(function(_, errCode, errMsg)
		if gen ~= gStream.gen then return end
		Stream_Retry("connection error " .. tostring(errMsg or errCode))
	end)
	SetTimer("STREAM_CONNECT_TIMEOUT", STREAM_CONNECT_TIMEOUT_MS, function()
		if gen == gStream.gen and not gStream.inBody then Stream_Retry("connect timeout") end
	end)
	cli:Connect(gCam.host, port)
end

local function StreamWatchdog()
	if gStream.connected and (os.time() - gStream.lastData) > STREAM_SILENCE_LIMIT_S then
		Stream_Retry("no data for " .. STREAM_SILENCE_LIMIT_S .. "s")
	end
end

--[[=============================================================================
    Snapshots and stream selection for Navigators
===============================================================================]]
-- Picture sizes offered when the camera can scale its snapshots (each one tested at refresh)
local SNAPSHOT_WIDTHS = { 320, 640, 1280 }
local NOTIFICATION_WIDTH = 1280

-- size = { w, h }: ask the camera to scale the picture (Hikvision videoResolutionWidth/Height)
local function SnapshotPath(n, size)
	local p = gInfo.snapshotBase .. StreamId(n) .. "/picture"
	if size then p = p .. "?videoResolutionWidth=" .. size.w .. "&videoResolutionHeight=" .. size.h end
	return p
end

-- The smallest tested size that covers the requested width; nil = a whole stream picture
local function SnapshotSizeFor(reqW)
	reqW = tonumber(reqW) or 0
	if reqW <= 0 then return nil end
	for _, s in ipairs(gInfo.snapshotSizes or {}) do
		if s.w >= reqW * 0.9 then return s end
	end
	return nil
end

-- Notifications: a phone-sized picture when the camera can scale. Otherwise the sub stream picture
-- (a few dozen KB) when it is at least 640 px wide, rather than a main stream picture that is often over 1 MB
local function NotificationSnapshotPath()
	local size = SnapshotSizeFor(NOTIFICATION_WIDTH)
	if size then return SnapshotPath(1, size) end
	local sub = gInfo.streams[2]
	if gInfo.plainSnapshot and not gInfo.snapshotMainOnly and sub and (sub.width or 0) >= 640 then return SnapshotPath(2) end
	return SnapshotPath(1)
end

CaptureEventSnapshot = function()
	if (Properties["Snapshot With Alerts"] or "Yes") ~= "Yes" then return end
	if os.time() - gState.lastSnapshotAt < 5 then return end
	gState.lastSnapshotAt = os.time()
	Isapi(gCam, "GET", "/" .. NotificationSnapshotPath(), nil, function(code, body)
		if code == 200 and IsJpeg(body) then
			gState.eventSnapshot = body
			LogDebug("Alert snapshot captured (%d bytes)", #body)
		end
	end, { timeout = 10 })
end

local function IsH264(s)
	return s and s.codec and string.find(s.codec, "264", 1, true) ~= nil
end

local function H264Streams()
	local list = {}
	for n, s in pairs(gInfo.streams) do
		if n <= 3 and s.enabled ~= false and IsH264(s) then list[#list + 1] = s end
	end
	table.sort(list, function(a, b) return (a.width or 0) < (b.width or 0) end)
	return list
end

function PickVideoStream(reqW)
	local quality = Properties["Video Quality"] or "Auto"
	local h264 = H264Streams()
	if quality == "High" then return #h264 > 0 and h264[#h264].n or 1 end
	if quality == "Low" then return #h264 > 0 and h264[1].n or 2 end
	reqW = tonumber(reqW) or 0
	if #h264 == 0 then return (reqW > 0 and reqW <= 800) and 2 or 1 end
	if reqW <= 0 then return h264[#h264].n end
	for _, s in ipairs(h264) do
		if (s.width or 0) >= reqW * 0.9 then return s.n end
	end
	return h264[#h264].n
end

function PickSnapshotStream(reqW)
	local quality = Properties["Video Quality"] or "Auto"
	if quality == "High" or gInfo.snapshotMainOnly then return 1 end
	if quality == "Low" then return gInfo.streams[2] and 2 or 1 end
	reqW = tonumber(reqW) or 0
	local sub = gInfo.streams[2]
	if reqW > 0 and sub and sub.enabled ~= false and sub.width and reqW <= sub.width * 1.25 then return 2 end
	if reqW > 0 and reqW <= 640 and next(gInfo.streams) == nil then return 2 end
	return 1
end

local function LogRequest(name, tParams)
	if LOG_LEVEL >= 4 then
		local parts = {}
		for k, v in pairs(tParams or {}) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
		LogDebug("%s(%s)", name, table.concat(parts, ", "))
	end
end

UI_REQ = {}

UI_REQ.GET_SNAPSHOT_QUERY_STRING = function(tParams)
	local size = (Properties["Video Quality"] or "Auto") == "Auto" and SnapshotSizeFor(tParams.SIZE_X) or nil
	local q = size and SnapshotPath(1, size) or SnapshotPath(PickSnapshotStream(tParams.SIZE_X))
	LogRequest("GET_SNAPSHOT_QUERY_STRING -> " .. q, tParams)
	return "<snapshot_query_string>" .. XmlEscape(q) .. "</snapshot_query_string>"
end

UI_REQ.GET_RTSP_H264_QUERY_STRING = function(tParams)
	local q = "Streaming/Channels/" .. StreamId(PickVideoStream(tParams.SIZE_X))
	LogRequest("GET_RTSP_H264_QUERY_STRING -> " .. q, tParams)
	return "<rtsp_h264_query_string>" .. XmlEscape(q) .. "</rtsp_h264_query_string>"
end
UI_REQ.GET_RTSP_H264_QUERY = UI_REQ.GET_RTSP_H264_QUERY_STRING

UI_REQ.GET_MJPEG_QUERY_STRING = function()
	local n = 2
	for i, s in pairs(gInfo.streams) do
		if s.codec and string.find(string.upper(s.codec), "MJPEG", 1, true) then n = i end
	end
	return "<mjpeg_query_string>" .. XmlEscape("ISAPI/Streaming/channels/" .. StreamId(n) .. "/httpPreview") .. "</mjpeg_query_string>"
end
UI_REQ.GET_MJPEG_QUERY = UI_REQ.GET_MJPEG_QUERY_STRING

--[[=============================================================================
    Device commands
===============================================================================]]
local function MotionPath()
	if gInfo.isRecorder then
		return "/ISAPI/ContentMgmt/InputProxy/channels/" .. Channel() .. "/video/motionDetection"
	end
	return "/ISAPI/System/Video/inputs/channels/" .. Channel() .. "/motionDetection"
end

local function PtzBase()
	return "/ISAPI/PTZCtrl/channels/" .. Channel()
end

local function SetMotionEnabledState(enabled)
	gState.motionEnabled = enabled
	SetVar("MOTION_DETECTION_ENABLED", enabled)
end

local function SetMotionDetection(enabled)
	ReadModifyWrite(gCam, MotionPath(), { { "enabled", enabled and "true" or "false" } },
		"Motion detection " .. (enabled and "on" or "off"), function(ok)
			if ok then SetMotionEnabledState(enabled) end
			if UpdateExtras then UpdateExtras() end
		end)
end

local DAY_NIGHT = { AUTO = "auto", DAY = "day", NIGHT = "night" }
local function SetDayNight(mode)
	local v = DAY_NIGHT[string.upper(mode or "")]
	if not v then
		LogError("Unknown day/night mode %s", mode)
		if UpdateExtras then UpdateExtras() end
		return
	end
	ReadModifyWrite(gCam, "/ISAPI/Image/channels/" .. Channel() .. "/IrcutFilter", { { "IrcutFilterType", v } }, "Day/night " .. v,
		function(ok)
			if ok then gInfo.dayNight = v end
			if UpdateExtras then UpdateExtras() end
		end)
end

local LIGHT_MODES = { SMART = "eventIntelligence", IR = "irLight", ["WHITE LIGHT"] = "colorVuWhiteLight", OFF = "close" }
local function SetLightMode(mode)
	local v = LIGHT_MODES[string.upper(mode or "")]
	if not v then
		for _, raw in pairs(LIGHT_MODES) do
			if raw == mode then v = raw end
		end
	end
	if not v then
		LogError("Unknown light mode %s", mode)
		if UpdateExtras then UpdateExtras() end
		return
	end
	ReadModifyWrite(gCam, "/ISAPI/Image/channels/" .. Channel() .. "/supplementLight", { { "supplementLightMode", v } }, "Light " .. v,
		function(ok)
			if ok then gInfo.lightMode = v end
			if UpdateExtras then UpdateExtras() end
		end)
end

local IMAGE_TAGS = { BRIGHTNESS = "brightnessLevel", CONTRAST = "contrastLevel", SATURATION = "saturationLevel", SHARPNESS = "SharpnessLevel" }
local function SetImage(setting, value)
	local tag = IMAGE_TAGS[string.upper(setting or "")]
	if not tag then return LogError("Unknown image setting %s", setting) end
	value = math.max(0, math.min(100, tonumber(value) or 50))
	local path = "/ISAPI/Image/channels/" .. Channel() .. (tag == "SharpnessLevel" and "/sharpness" or "/color")
	ReadModifyWrite(gCam, path, { { tag, tostring(value) } }, setting .. " " .. value)
end

local function SetAlarmOutput(output, state, pulseSeconds)
	output = tonumber(output) or 1
	local function trigger(high, cb)
		local body = "<IOPortData><outputState>" .. (high and "high" or "low") .. "</outputState></IOPortData>"
		Isapi(gCam, "PUT", "/ISAPI/System/IO/outputs/" .. output .. "/trigger", body, function(code, rbody, err)
			if IsOkResponse(code, rbody) then LogInfo("Alarm output %d %s", output, high and "on" or "off")
			else LogError("Alarm output %d failed: %s", output, ResponseError(code, rbody, err)) end
			if cb then cb() end
		end)
	end
	state = string.upper(state or "ON")
	if state == "PULSE" then
		trigger(true, function()
			SetTimer("ALARM_OUT_" .. output, (tonumber(pulseSeconds) or 2) * 1000, function() trigger(false) end)
		end)
	else
		KillTimer("ALARM_OUT_" .. output)
		trigger(state == "ON")
	end
end

local function PtzContinuous(pan, tilt, zoom)
	local speed = tonumber(Properties["PTZ Speed"]) or 50
	local body = string.format("<PTZData><pan>%d</pan><tilt>%d</tilt><zoom>%d</zoom></PTZData>", pan * speed, tilt * speed, zoom * speed)
	Isapi(gCam, "PUT", PtzBase() .. "/continuous", body, function(code, rbody, err)
		if not IsOkResponse(code, rbody) then
			LogError("PTZ move failed: %s", ResponseError(code, rbody, err))
			return
		end
		SetTimer("PTZ_STOP", 500, function()
			Isapi(gCam, "PUT", PtzBase() .. "/continuous", "<PTZData><pan>0</pan><tilt>0</tilt><zoom>0</zoom></PTZData>")
		end)
	end)
end

local function PtzGotoPreset(n)
	n = tonumber(n)
	if not n then return end
	Isapi(gCam, "PUT", PtzBase() .. "/presets/" .. n .. "/goto", "", function(code, body, err)
		if not IsOkResponse(code, body) then LogError("Preset %d failed: %s", n, ResponseError(code, body, err)) end
	end)
end

local function PtzHome()
	Isapi(gCam, "PUT", PtzBase() .. "/homeposition/goto", "", function(code, body)
		if not IsOkResponse(code, body) then PtzGotoPreset(1) end
	end)
end

local function RebootCamera()
	LogWarn("Rebooting camera %s", gCam.host)
	Isapi(gCam, "PUT", "/ISAPI/System/reboot", "", function(code, body, err)
		if IsOkResponse(code, body) then LogInfo("Camera is rebooting")
		else LogError("Reboot failed: %s", ResponseError(code, body, err)) end
	end)
end

--[[=============================================================================
    Touchscreen controls in the camera view (Extras)
    Object types follow Snap One's sample extras setup (button / checkbox / list).
===============================================================================]]
local EXTRAS_ALERT_ON = { { "Any detection", "Any detection" }, { "People and vehicles", "People and vehicles" }, { "People only", "People only" } }
local EXTRAS_DAY_NIGHT = { { "Auto", "auto" }, { "Day", "day" }, { "Night", "night" } }
local EXTRAS_LIGHT = { { "Smart", "eventIntelligence" }, { "IR", "irLight" }, { "White light", "colorVuWhiteLight" }, { "Off", "close" } }

local function ExtrasList(id, label, command, items)
	local t = { '<object type="list" id="' .. id .. '" label="' .. XmlEscape(label) .. '" command="' .. command .. '">',
		'<list maxselections="1" minselections="1">' }
	for _, it in ipairs(items) do
		t[#t + 1] = '<item text="' .. XmlEscape(it[1]) .. '" value="' .. XmlEscape(it[2]) .. '"/>'
	end
	t[#t + 1] = "</list></object>"
	return table.concat(t)
end

function ExtrasSetupXml()
	local x = { "<extras_setup><extra>", '<section label="Alerts">',
		'<object type="checkbox" id="alerts" label="Alerts from this camera" command="EXTRAS_ALERTS"/>',
		ExtrasList("alerton", "Alert on", "EXTRAS_ALERT_ON", EXTRAS_ALERT_ON),
		'<object type="button" id="snooze" label="Pause alerts for 1 hour" command="EXTRAS_SNOOZE"><buttontext>Snooze</buttontext></object>',
		'</section><section label="Camera">',
		'<object type="checkbox" id="motion" label="Motion detection" command="EXTRAS_MOTION"/>',
		ExtrasList("daynight", "Day / night", "EXTRAS_DAY_NIGHT", EXTRAS_DAY_NIGHT) }
	if gInfo.lightSupported then x[#x + 1] = ExtrasList("light", "Light", "EXTRAS_LIGHT", EXTRAS_LIGHT) end
	x[#x + 1] = '</section><section label="Maintenance">'
	x[#x + 1] = '<object type="button" id="reboot" label="Restart the camera" command="EXTRAS_REBOOT"><buttontext>Reboot</buttontext></object>'
	x[#x + 1] = "</section></extra></extras_setup>"
	return table.concat(x)
end

function ExtrasStateXml()
	local o = {}
	local function add(id, v)
		if v ~= nil then o[#o + 1] = '<object id="' .. id .. '" value="' .. XmlEscape(v) .. '"/>' end
	end
	add("alerts", AlertsEnabled() and "True" or "False")
	add("alerton", Properties["Alert On"] or "Any detection")
	if gState.motionEnabled ~= nil then add("motion", gState.motionEnabled and "True" or "False") end
	add("daynight", gInfo.dayNight)
	if gInfo.lightSupported then add("light", gInfo.lightMode) end
	return "<extras_state><extra>" .. table.concat(o) .. "</extra></extras_state>"
end

local function SendExtrasSetup()
	pcall(function() C4:SendToProxy(CAMERA_PROXY, "EXTRAS_SETUP_CHANGED", { XML = ExtrasSetupXml() }, "NOTIFY") end)
end

-- Every Extras command must be answered with a state update within 10 s, or the UI reverts
UpdateExtras = function()
	pcall(function() C4:SendToProxy(CAMERA_PROXY, "EXTRAS_STATE_CHANGED", { XML = ExtrasStateXml() }, "NOTIFY") end)
end

UI_REQ.GET_EXTRAS_SETUP = function() return ExtrasSetupXml() end
UI_REQ.GET_EXTRAS_STATE = function() return ExtrasStateXml() end

--[[=============================================================================
    Hub link
===============================================================================]]
ReportToHub = function(force)
	if not gCfg.hubId then return end
	local p = {
		DEVICE_ID = MyDeviceId(), PROXY_ID = ProxyId(), NAME = CameraName(),
		ADDRESS = gCam.host, PORT = gCfg.httpPort, CHANNEL = Channel(),
		ONLINE = gState.online == true and "1" or (gState.online == false and "0" or ""),
		DISABLED = CameraEnabled() and "0" or "1",
		SNAPSHOT = NotificationSnapshotPath(),
		NEED_LOGIN = HasLogin() and "0" or "1",
		H264 = next(gInfo.streams) == nil and "" or (#H264Streams() > 0 and "1" or "0"),
		LOGIN_FAILED = gCam.authFailed and "1" or "0",
		ALERT_ACTIVE = gState.alertActive and "1" or "0",
		ALERTS = (Properties["Alerts"] or "On") == "On" and "1" or "0",
		MODEL = gInfo.model, STATUS = Properties["Status"] or "", VERSION = DRIVER_SEMVER,
	}
	local sig = table.concat({ p.NAME, p.ADDRESS, p.PORT, p.CHANNEL, p.ONLINE, p.DISABLED, p.SNAPSHOT, p.NEED_LOGIN, p.H264, p.LOGIN_FAILED, p.ALERT_ACTIVE, p.ALERTS, p.MODEL, p.STATUS }, "|")
	if sig == gState.lastHubReport and not force then return end
	gState.lastHubReport = sig
	SendToDriver(gCfg.hubId, "DL_CAMERA_STATUS", p)
end

local function UpdateHubProperty()
	local name
	if gCfg.hubId then
		local ok, n = pcall(function() return C4:GetDeviceDisplayName(gCfg.hubId) end)
		name = (ok and n and n ~= "") and n or ("device " .. gCfg.hubId)
	end
	if name and not string.find(string.lower(name), "hub", 1, true) then name = "Hikvision Hub (" .. name .. ")" end
	UpdateProperty("Managed By", name or "Standalone (set up on the camera's Properties page)")
end

--[[=============================================================================
    Camera information refresh
===============================================================================]]
local function StreamDescription(s)
	if not s then return nil end
	local txt = (s.codec or "?") .. " " .. tostring(s.width or "?") .. "x" .. tostring(s.height or "?")
	if s.fps then txt = txt .. " " .. s.fps .. "fps" end
	return txt
end

local function ParseStreamingChannel(sc)
	local id = tonumber(XmlChildValue(sc, "id") or "")
	if not id then return nil end
	local fps = tonumber(XmlChildValue(sc, "Video/maxFrameRate") or "")
	return {
		id = id, n = id % 100,
		enabled = XmlChildValue(sc, "enabled") ~= "false",
		codec = XmlChildValue(sc, "Video/videoCodecType"),
		width = tonumber(XmlChildValue(sc, "Video/videoResolutionWidth") or ""),
		height = tonumber(XmlChildValue(sc, "Video/videoResolutionHeight") or ""),
		fps = fps and (fps >= 100 and math.floor(fps / 100 + 0.5) or fps) or nil,
	}
end

-- Label of a detection the driver turns into Control4 events; nil for device faults (disk full, ...)
local function EventLabel(etype)
	local key = EVENT_TYPE_MAP[string.lower(etype)]
	return key and DETECTIONS[key].label or nil
end

local function RunSteps(steps, gen, done)
	local i = 0
	local function nextStep()
		if gen ~= gState.refreshGen then return end
		i = i + 1
		local step = steps[i]
		if not step then
			if done then done() end
			return
		end
		local ok, err = pcall(step, nextStep)
		if not ok then
			LogError("Refresh step %d failed: %s", i, err)
			nextStep()
		end
	end
	nextStep()
end

Refresh = function()
	if os.time() - (gState.pageWrittenAt or 0) > 10 then SyncFromCameraPage() end
	ApplyConnection()
	gState.refreshGen = gState.refreshGen + 1
	local gen = gState.refreshGen
	if not CameraEnabled() or not ValidAddress(gCam.host) or not HasLogin() then
		gState.refreshing = false
		Stream_Stop()
		UpdateStatus()
		return
	end
	gState.refreshing = true
	gInfo.notIsapi = false
	gStream.auth = NewAuth()
	UpdateStatus()
	LogInfo("Refreshing camera %s (channel %d)", gCam.host, Channel())

	local steps = {
		function(nextStep) -- 1. device information
			Isapi(gCam, "GET", "/ISAPI/System/deviceInfo", nil, function(code, body, err)
				if code == 200 then
					local info = ParseDeviceInfo(body)
					gInfo.model, gInfo.firmware, gInfo.deviceName = info.model, info.firmware, info.name
					gInfo.isRecorder = info.isRecorder
					UpdateProperty("Camera", trim(info.model .. "  -  " .. info.firmware .. (info.isRecorder and ("  -  NVR channel " .. Channel()) or "")))
					gState.needRefresh = false
					if gInfo.isRecorder then
						CheckChannel(nextStep) -- online only if the NVR's camera is connected
					else
						SetChannelOffline(false)
						SetOnline(true)
						nextStep()
					end
				elseif code == 401 then
					gState.needRefresh = true
					gState.refreshing = false
					UpdateStatus()
				elseif code == 404 then
					gInfo.notIsapi = true
					gState.needRefresh = false
					gState.refreshing = false
					SetOnline(true)
					Stream_Stop()
					UpdateStatus()
				elseif code then
					SetOnline(true)
					gState.needRefresh = false
					nextStep()
				else
					gState.needRefresh = true
					gState.refreshing = false
					SetOnline(false)
					SetTimer("REFRESH_RETRY", REFRESH_RETRY_MS, function() Refresh() end)
				end
			end, { force = true })
		end,
		function(nextStep) -- 2. stream configuration
			local ch, streams = Channel(), {}
			local function finish()
				gInfo.streams = streams
				local parts = {}
				if streams[1] then parts[#parts + 1] = "Main " .. StreamDescription(streams[1]) end
				if streams[2] then parts[#parts + 1] = "Sub " .. StreamDescription(streams[2]) end
				UpdateProperty("Video", table.concat(parts, "  -  "))
				if next(streams) ~= nil and #H264Streams() == 0 then
					SetAttention("video", gState.h264Error
						and ("No H.264 stream, and the camera refused H.264 on its sub stream (" .. gState.h264Error .. "). Set it on the camera's web page: Configuration > Video/Audio > Sub Stream > Video Encoding")
						or "No H.264 stream, and Control4 cannot play H.265: run Actions > Set Sub Stream To H.264 so touchscreens can play video")
				else
					SetAttention("video", nil)
				end
				nextStep()
			end
			Isapi(gCam, "GET", "/ISAPI/Streaming/channels", nil, function(code, body)
				if code == 200 then
					for _, sc in ipairs(XmlFindAll(XmlParse(body), "StreamingChannel")) do
						local s = ParseStreamingChannel(sc)
						if s and math.floor(s.id / 100) == ch then streams[s.n] = s end
					end
				end
				if next(streams) ~= nil then return finish() end
				local n = 0
				local function fetchNext()
					n = n + 1
					if n > 3 then return finish() end
					Isapi(gCam, "GET", "/ISAPI/Streaming/channels/" .. (ch * 100 + n), nil, function(c2, b2)
						if c2 == 200 then
							local s = ParseStreamingChannel(XmlFind(XmlParse(b2), "StreamingChannel"))
							if s then streams[s.n] = s end
						end
						fetchNext()
					end)
				end
				fetchNext()
			end)
		end,
		function(nextStep) -- 3. snapshots: sub stream, else main stream; NVRs may need the streaming proxy path
			gInfo.plainSnapshot = nil
			local bases = { "ISAPI/Streaming/channels/" }
			if gInfo.isRecorder then bases[2] = "ISAPI/ContentMgmt/StreamingProxy/channels/" end
			local tries = {}
			for _, base in ipairs(bases) do
				if gInfo.streams[2] then tries[#tries + 1] = { base, 2 } end
				tries[#tries + 1] = { base, 1 }
			end
			if gState.channelOffline then return nextStep() end -- no picture to test; Attention already says why
			local i, lastErr = 0, nil
			local function try()
				i = i + 1
				local t = tries[i]
				if not t then
					gInfo.snapshotBase, gInfo.snapshotMainOnly = "ISAPI/Streaming/channels/", false
					LogWarn("Snapshot test failed (%s)", tostring(lastErr))
					SetAttention("snapshot", "The camera gives no snapshot (" .. tostring(lastErr) .. ")"
						.. (gInfo.isRecorder and ": the camera on this NVR channel may be offline" or ""))
					return nextStep()
				end
				Isapi(gCam, "GET", "/" .. t[1] .. StreamId(t[2]) .. "/picture", nil, function(code, body, err)
					if code == 200 and IsJpeg(body) then
						local w, h = JpegSize(body)
						gInfo.plainSnapshot = { n = t[2], w = w, h = h, bytes = #body }
						gInfo.snapshotBase, gInfo.snapshotMainOnly = t[1], (t[2] == 1)
						if t[2] == 1 and gInfo.streams[2] then LogInfo("Snapshots come from the main stream (the sub stream gives none)") end
						SetAttention("snapshot", nil)
						return nextStep()
					end
					lastErr = ResponseError(code, body, err)
					try()
				end, { timeout = 15 })
			end
			try()
		end,
		function(nextStep) -- 3b. can the camera scale its pictures? Small tiles then cost a few KB, not a full-size JPEG
			gInfo.snapshotSizes, gInfo.scaleNote = {}, nil
			if gState.channelOffline or not gInfo.plainSnapshot then return nextStep() end
			local ratio = 9 / 16
			local main = gInfo.streams[1]
			if main and main.width and main.height and main.width > 0 then
				local r = main.height / main.width
				if math.abs(r - 0.75) < math.abs(r - 0.5625) then ratio = 3 / 4 end
			end
			local i = 0
			local function nextSize()
				i = i + 1
				local w = SNAPSHOT_WIDTHS[i]
				if not w then return nextStep() end
				local size = { w = w, h = math.floor(w * ratio + 0.5) }
				Isapi(gCam, "GET", "/" .. SnapshotPath(1, size), nil, function(code, body, err)
					local jw = (code == 200 and IsJpeg(body)) and JpegSize(body) or nil
					if jw and jw <= size.w * 1.1 then
						size.bytes = #body
						gInfo.snapshotSizes[#gInfo.snapshotSizes + 1] = size
						return nextSize()
					end
					-- The camera ignores or refuses sizes: whole stream pictures, as before
					if i == 1 then
						gInfo.scaleNote = jw and ("it ignores the requested size and sends " .. jw .. " px") or ("it refuses it: " .. ResponseError(code, body, err))
						LogInfo("Snapshots: the camera does not scale pictures (%s)", gInfo.scaleNote)
					end
					nextStep()
				end, { timeout = 15 })
			end
			nextSize()
		end,
		function(nextStep) -- 4. which detections notify Control4
			Isapi(gCam, "GET", "/ISAPI/Event/triggers", nil, function(code, body)
				local center, other, seen = {}, {}, {}
				if code == 200 then
					for _, t in ipairs(XmlFindAll(XmlParse(body), "EventTrigger")) do
						local etype = XmlChildValue(t, "eventType") or ""
						local tch = tonumber(XmlChildValue(t, "videoInputChannelID") or XmlChildValue(t, "dynVideoInputChannelID") or "")
						local label = EventLabel(etype)
						if label and (tch == nil or tch == Channel()) then
							local notifies = false
							for _, m in ipairs(XmlFindAll(t, "notificationMethod")) do
								local mv = string.lower(XmlValue(m) or "")
								if mv == "center" or mv == "http" then notifies = true end
							end
							if not seen[label] then
								seen[label] = true
								if notifies then center[#center + 1] = label else other[#other + 1] = label end
							end
						end
					end
					gInfo.centerEvents, gInfo.otherEvents = center, other
					UpdateProperty("Events", #center > 0 and table.concat(center, ", ") or "None")
					if #center == 0 then
						SetAttention("events", "No detection sends events: on the camera, tick 'Notify Surveillance Center' for each detection")
					else
						SetAttention("events", nil)
					end
				else
					UpdateProperty("Events", "Unknown")
				end
				nextStep()
			end)
		end,
		function(nextStep) -- 5. PTZ
			Isapi(gCam, "GET", PtzBase() .. "/capabilities", nil, function(code, body)
				gInfo.ptzPanTilt, gInfo.ptzZoom = false, false
				if code == 200 and body and not string.find(body, "<ResponseStatus", 1, true) then
					gInfo.ptzPanTilt = string.find(body, "ContinuousPanTiltSpace", 1, true) ~= nil
					gInfo.ptzZoom = string.find(body, "ContinuousZoomSpace", 1, true) ~= nil
				end
				pcall(function()
					C4:SendToProxy(CAMERA_PROXY, "DYNAMIC_CAPABILITIES_CHANGED", {
						has_pan = tostring(gInfo.ptzPanTilt), has_tilt = tostring(gInfo.ptzPanTilt),
						has_zoom = tostring(gInfo.ptzZoom), has_home = tostring(gInfo.ptzPanTilt),
					}, "NOTIFY")
				end)
				nextStep()
			end)
		end,
		function(nextStep) -- 6. RTSP port: keep the camera Properties page in step with the camera
			Isapi(gCam, "GET", "/ISAPI/Security/adminAccesses", nil, function(code, body)
				if code == 200 then
					for _, p in ipairs(XmlFindAll(XmlParse(body), "AdminAccessProtocol")) do
						if string.upper(XmlChildValue(p, "protocol") or "") == "RTSP" then
							local port = tonumber(XmlChildValue(p, "portNo") or "")
							if port and port ~= gCfg.rtspPort then
								LogWarn("Camera RTSP port is %d; updating the camera's Properties page", port)
								gCfg.rtspPort = port
								SaveCfg()
								WriteProxySettings()
							end
						end
					end
				end
				nextStep()
			end)
		end,
		function(nextStep) -- 7. motion detection, day/night and light state
			Isapi(gCam, "GET", MotionPath(), nil, function(code, body)
				if code == 200 then
					local enabled = XmlChildValue(XmlFind(XmlParse(body), "MotionDetection"), "enabled")
					if enabled then SetMotionEnabledState(enabled == "true") end
				end
				Isapi(gCam, "GET", "/ISAPI/Image/channels/" .. Channel() .. "/IrcutFilter", nil, function(c2, b2)
					gInfo.dayNight = nil
					if c2 == 200 then
						local v = XmlGet(XmlParse(b2), "IrcutFilterType")
						if v then gInfo.dayNight = string.lower(v) end
					end
					Isapi(gCam, "GET", "/ISAPI/Image/channels/" .. Channel() .. "/supplementLight", nil, function(c3, b3)
						gInfo.lightSupported, gInfo.lightMode = false, nil
						if c3 == 200 then
							local v = XmlGet(XmlParse(b3), "supplementLightMode")
							if v then gInfo.lightSupported, gInfo.lightMode = true, v end
						end
						nextStep()
					end)
				end)
			end)
		end,
	}

	RunSteps(steps, gen, function()
		gState.refreshing = false
		LogInfo("Camera ready: %s %s", gInfo.model, gInfo.firmware)
		pcall(function() C4:SendToProxy(CAMERA_PROXY, "DYNAMIC_URLS_CHANGED", {}, "NOTIFY") end)
		SendExtrasSetup()
		UpdateExtras()
		if not gStream.connected then Stream_Start() end
		UpdateStatus()
		if gCfg.h264Pending then
			if gState.channelOffline then
				LogInfo("Sub stream: H.264 will be set when the camera on NVR channel %d is back", Channel())
			else
				gCfg.h264Pending = false
				SaveCfg()
				SetSubStreamH264()
			end
		end
	end)
end

local function ScheduleRefresh(ms)
	SetTimer("REFRESH", ms or 2000, function() Refresh() end)
end

-- Connection changed (Composer, the camera page or the hub)
local function ConfigChanged()
	ApplyConnection()
	gStream.pathIndex = 1
	Stream_Stop()
	ScheduleRefresh(1500)
end

-- Camera Enabled = No: no events, alerts, health checks or camera requests; the hub ignores it
local function EnabledChanged()
	if CameraEnabled() then
		LogInfo("Camera enabled")
		gStream.fails = 0
		SetTargetAuthFailed(gCam, false)
		ConfigChanged()
	else
		LogInfo("Camera disabled: no events, alerts or health checks")
		gState.refreshGen = gState.refreshGen + 1
		gState.refreshing = false
		KillTimer("REFRESH")
		KillTimer("REFRESH_RETRY")
		Stream_Stop()
		EndAllDetections()
		gState.online = nil
		SetVar("ONLINE", false)
	end
	UpdateStatus()
	ReportToHub(true)
end

--[[=============================================================================
    Sub stream to H.264
    Control4 touchscreens and the app play H.264 only. The main stream can stay
    H.265 (recording); the sub stream is switched to H.264 for Control4.
===============================================================================]]
SetSubStreamH264 = function(done)
	done = done or function() end
	local path = "/ISAPI/Streaming/channels/" .. StreamId(2)
	local function result(ok, msg, reason)
		if ok then LogInfo("Sub stream: %s", msg) else LogError("Sub stream: %s", msg) end
		print("Set Sub Stream To H.264: " .. msg)
		gState.h264Error = (not ok) and reason or nil
		done(ok, msg)
	end
	if not CameraEnabled() then return result(false, "the camera is disabled") end
	Isapi(gCam, "GET", path, nil, function(code, body, err)
		if code ~= 200 or not body or body == "" then
			return result(false, "cannot read the sub stream settings: " .. ResponseError(code, body, err))
		end
		local codec = XmlGet(XmlParse(body), "videoCodecType") or ""
		if string.find(codec, "264", 1, true) then return result(true, "already H.264") end
		local doc, replaced = XmlReplaceValue(body, "videoCodecType", "H.264")
		if not replaced then return result(false, "this camera does not report a video codec for its sub stream") end
		-- H.264 has its own profile; Smart Codec (H.265+/H.264+) is not used on a sub stream
		doc = string.gsub(doc, "<H265Profile>[^<]*</H265Profile>", "<H264Profile>Main</H264Profile>")
		doc = string.gsub(doc, "(<SmartCodec>%s*<enabled>)true(</enabled>)", "%1false%2")
		Isapi(gCam, "PUT", path, doc, function(pcode, pbody, perr)
			local sc = pbody and string.match(pbody, "<statusCode>%s*(%d+)%s*</statusCode>")
			if IsOkResponse(pcode, pbody) or (pcode == 200 and sc == "7") then
				result(true, "changed from " .. codec .. " to H.264" .. (sc == "7" and " (the camera applies it after a reboot)" or ""))
				gInfo.streams = {}
				ScheduleRefresh(3000)
			else
				local reason = ResponseError(pcode, pbody, perr)
				result(false, "the camera refused H.264 on its sub stream: " .. reason
					.. ". Change it on the camera's web page: Configuration > Video/Audio > Sub Stream > Video Encoding", reason)
				ScheduleRefresh(1000) -- shows the reason in Attention
			end
		end)
	end)
end

--[[=============================================================================
    Report (Actions tab)
===============================================================================]]
local function PrintReport()
	local lines = {
		"===== Hikvision camera - setup report =====",
		"Status        : " .. tostring(Properties["Status"]),
		"Name          : " .. CameraName(),
		"Enabled       : " .. (CameraEnabled() and "yes" or "NO (Camera Enabled = No)"),
		"Address       : " .. gCam.host .. "  HTTP " .. tostring(gCfg.httpPort) .. "  HTTPS " .. tostring(gCfg.httpsPort)
			.. (gCam.https and " (in use)" or "") .. "  RTSP " .. tostring(gCfg.rtspPort),
		"Login         : " .. (gCam.user ~= "" and gCam.user or "(not set)") .. ", password " .. (gCam.pass ~= "" and "set" or "NOT SET"),
		"Managed by    : " .. tostring(Properties["Managed By"]),
		"Camera        : " .. tostring(Properties["Camera"]),
		"Channel       : " .. Channel(),
		"Alerts        : " .. AlertsDescription() .. " - alert on: " .. tostring(Properties["Alert On"]),
		"Events        : " .. tostring(Properties["Events"]),
		"Not sending   : " .. table.concat(gInfo.otherEvents, ", "),
		"PTZ           : pan/tilt " .. tostring(gInfo.ptzPanTilt) .. ", zoom " .. tostring(gInfo.ptzZoom),
		"Day/night     : " .. tostring(gInfo.dayNight) .. "   light: " .. (gInfo.lightSupported and tostring(gInfo.lightMode) or "none"),
	}
	for n = 1, 4 do
		local s = gInfo.streams[n]
		if s then lines[#lines + 1] = string.format("Stream %d      : %s (%d)%s", n, StreamDescription(s), s.id, IsH264(s) and "" or "  not playable on touchscreens") end
	end
	lines[#lines + 1] = "Video URL     : rtsp://" .. gCam.host .. ":" .. gCfg.rtspPort .. "/Streaming/Channels/" .. StreamId(PickVideoStream(1920)) .. " (full screen)"
	lines[#lines + 1] = "Snapshot URL  : " .. TargetBaseUrl(gCam) .. "/" .. (SnapshotSizeFor(320) and SnapshotPath(1, SnapshotSizeFor(320)) or SnapshotPath(PickSnapshotStream(320))) .. " (tiles)"
	local function kb(b) return b and (b >= 1048576 and string.format("%.1f MB", b / 1048576) or string.format("%d KB", math.floor(b / 1024 + 0.5))) or "?" end
	local ps = gInfo.plainSnapshot
	local sizes = {}
	if ps then sizes[#sizes + 1] = string.format("stream %d: %sx%s %s", ps.n, tostring(ps.w or "?"), tostring(ps.h or "?"), kb(ps.bytes)) end
	for _, s in ipairs(gInfo.snapshotSizes or {}) do sizes[#sizes + 1] = string.format("%dx%d %s", s.w, s.h, kb(s.bytes)) end
	lines[#lines + 1] = "Snapshot size : " .. (#sizes > 0 and table.concat(sizes, "  -  ") or "not measured")
		.. ((#(gInfo.snapshotSizes or {}) == 0 and ps) and ("  (the camera does not scale pictures: " .. tostring(gInfo.scaleNote or "not tested") .. ")") or "")
	if #H264Streams() == 0 and next(gInfo.streams) ~= nil then
		lines[#lines + 1] = "NOTE          : no H.264 stream - Control4 cannot play H.265. Run Actions > Set Sub Stream To H.264"
	end
	if Properties["Attention"] and Properties["Attention"] ~= "" then lines[#lines + 1] = "ATTENTION     : " .. Properties["Attention"] end
	lines[#lines + 1] = "============================================"
	print(table.concat(lines, "\n"))
end

--[[=============================================================================
    Commands, actions, proxy messages
===============================================================================]]
local ACTIONS = {
	Reconnect = function()
		SetTargetAuthFailed(gCam, false)
		gStream.fails = 0
		ConfigChanged()
	end,
	TestSnapshot = function()
		local tile = SnapshotSizeFor(320)
		local pictures = {
			{ "tile", tile and SnapshotPath(1, tile) or SnapshotPath(PickSnapshotStream(320)) },
			{ "notification", NotificationSnapshotPath() },
			{ "full screen", SnapshotPath(1) },
		}
		for _, req in ipairs(pictures) do
			local path = "/" .. req[2]
			Isapi(gCam, "GET", path, nil, function(code, body, err)
				if code == 200 and IsJpeg(body) then
					local w, h = JpegSize(body)
					print(string.format("Snapshot %s OK: %s - %sx%s, %d KB", req[1], path, tostring(w or "?"), tostring(h or "?"), math.floor(#body / 1024 + 0.5)))
				else
					print("Snapshot " .. req[1] .. " FAILED: " .. path .. " -> " .. ResponseError(code, body, err))
				end
			end, { force = true })
		end
		local probe = "/" .. SnapshotPath(1, { w = 320, h = 180 })
		Isapi(gCam, "GET", probe, nil, function(code, body, err)
			local w, h
			if code == 200 and IsJpeg(body) then w, h = JpegSize(body) end
			if w and w <= 352 then
				print(string.format("Snapshot resize OK: the camera scales pictures (%dx%d, %d KB)", w, h or 0, math.floor(#body / 1024 + 0.5)))
			elseif w then
				print(string.format("Snapshot resize: the camera ignores the requested size and sends %dx%d - tiles use the sub stream", w, h or 0))
			else
				print("Snapshot resize: the camera refuses it (" .. ResponseError(code, body, err) .. ") - tiles use the sub stream")
			end
		end, { force = true })
	end,
	Report = PrintReport,
	Reboot = RebootCamera,
	SubStreamH264 = function() SetSubStreamH264() end,
}

local COMMANDS = {
	SET_ALERTS = function(p)
		local s = string.upper(p["State"] or "TOGGLE")
		if s == "ON" then SetAlerts(true, "programming")
		elseif s == "OFF" then SetAlerts(false, "programming")
		else SetAlerts(not AlertsEnabled(), "programming") end
	end,
	SNOOZE_ALERTS = function(p) SnoozeAlerts(p["Minutes"], "programming") end,
	SET_ALERT_ON = function(p)
		if ALERT_FILTERS[p["Alert On"] or ""] then
			UpdateProperty("Alert On", p["Alert On"])
			UpdateExtras()
		end
	end,
	SET_MOTION_DETECTION = function(p) SetMotionDetection((p["State"] or "On") == "On") end,
	SET_DAY_NIGHT = function(p) SetDayNight(p["Mode"]) end,
	SET_LIGHT_MODE = function(p) SetLightMode(p["Mode"]) end,
	SET_IMAGE = function(p) SetImage(p["Setting"], p["Value"]) end,
	SET_ALARM_OUTPUT = function(p) SetAlarmOutput(p["Output"], p["State"], p["Pulse Seconds"]) end,
	GOTO_PRESET = function(p) PtzGotoPreset(p["Preset"]) end,
	REBOOT_CAMERA = function() RebootCamera() end,

	-- Messages from the Hikvision Hub
	DL_CONFIGURE = function(p)
		gCfg.hubId = tonumber(p.HUB_ID) or gCfg.hubId
		if p.HUB_ALERTS then gCfg.hubAlerts = toboolean(p.HUB_ALERTS) end
		if ValidAddress(p.ADDRESS) then gCfg.host = trim(p.ADDRESS) end
		if tonumber(p.HTTP_PORT) then gCfg.httpPort = tonumber(p.HTTP_PORT) end
		if p.CHANNEL then UpdateProperty("Channel", tostring(tonumber(p.CHANNEL) or 1)) end
		if p.ALERT_ON and ALERT_FILTERS[p.ALERT_ON] then UpdateProperty("Alert On", p.ALERT_ON) end
		if p.USERNAME then gCfg.user = p.USERNAME end
		if p.PASSWORD then gCfg.pass = p.PASSWORD end
		-- Hub setting "Sub Stream To H.264" = Automatic: done when the next refresh finishes
		if p.FIX_SUBSTREAM == "1" then gCfg.h264Pending = true end
		if p.NAME and p.NAME ~= "" then
			gCfg.name = p.NAME
			if p.RENAME == "1" then
				local pid = ProxyId()
				local okName, current = pcall(function() return C4:GetDeviceDisplayName(pid) end)
				if pid and not (okName and current == p.NAME) then pcall(function() C4:RenameDevice(pid, p.NAME) end) end
			end
		end
		SaveCfg()
		ApplyConnection()
		LogInfo("Configured by the hub: %s (channel %s)", gCam.host, Properties["Channel"])
		UpdateHubProperty()
		WriteProxySettings()
		AlertsChanged("hub")
		gState.lastHubReport = nil
		ConfigChanged()
	end,
	DL_HUB_ALERTS = function(p)
		gCfg.hubId = tonumber(p.HUB_ID) or gCfg.hubId
		gCfg.hubAlerts = toboolean(p.ENABLED)
		SaveCfg()
		AlertsChanged("hub")
	end,
	DL_HUB_HELLO = function(p)
		gCfg.hubId = tonumber(p.HUB_ID) or gCfg.hubId
		if p.HUB_ALERTS then gCfg.hubAlerts = toboolean(p.HUB_ALERTS) end
		SaveCfg()
		UpdateHubProperty()
		AlertsChanged("hub")
		ReportToHub(true)
	end,
	DL_FIX_SUBSTREAM = function() SetSubStreamH264() end,
}

local EXTRAS_COMMANDS = {
	EXTRAS_ALERTS = function(v) SetAlerts(toboolean(v), "camera controls") end,
	EXTRAS_ALERT_ON = function(v) COMMANDS.SET_ALERT_ON({ ["Alert On"] = v }) end,
	EXTRAS_SNOOZE = function() SnoozeAlerts(60, "camera controls") end,
	EXTRAS_MOTION = function(v) SetMotionDetection(toboolean(v)) end,
	EXTRAS_DAY_NIGHT = function(v) SetDayNight(v) end,
	EXTRAS_LIGHT = function(v) SetLightMode(v) end,
	EXTRAS_REBOOT = function()
		RebootCamera()
		UpdateExtras()
	end,
}
local EXTRAS_IDS = { EXTRAS_ALERTS = "alerts", EXTRAS_ALERT_ON = "alerton", EXTRAS_MOTION = "motion", EXTRAS_DAY_NIGHT = "daynight", EXTRAS_LIGHT = "light" }

local function FirstParam(p, ...)
	for _, k in ipairs({ ... }) do
		if p[k] ~= nil then return p[k] end
	end
	return nil
end

-- Edits made on the camera's Properties page arrive as these commands
local function FromCameraPage(field, value, reconnect)
	if value == nil or gCfg[field] == value then return end
	LogInfo("Camera page: %s changed", field)
	gCfg[field] = value
	SaveCfg()
	if reconnect then ConfigChanged() else ApplyConnection() end
end

-- Commands the camera proxy forwards when its Properties page changes, plus PTZ
local PRX_CMD = {
	SET_ADDRESS = function(p)
		local a = FirstParam(p, "ADDRESS", "VALUE")
		if ValidAddress(a) then FromCameraPage("host", trim(a), true) end
	end,
	SET_HTTP_PORT = function(p)
		local v = tonumber(FirstParam(p, "PORT", "HTTP_PORT", "VALUE"))
		if v then FromCameraPage("httpPort", v, true) end
	end,
	SET_HTTPS_PORT = function(p)
		local v = tonumber(FirstParam(p, "PORT", "HTTPS_PORT", "VALUE"))
		if v then FromCameraPage("httpsPort", v, gCfg.https) end
	end,
	SET_RTSP_PORT = function(p)
		local v = tonumber(FirstParam(p, "PORT", "RTSP_PORT", "VALUE"))
		if v then FromCameraPage("rtspPort", v, false) end
	end,
	SET_USE_HTTPS = function(p)
		local v = FirstParam(p, "USE_HTTPS", "VALUE", "ENABLED")
		if v ~= nil then FromCameraPage("https", toboolean(v), true) end
	end,
	SET_USERNAME = function(p)
		local v = FirstParam(p, "USERNAME", "VALUE")
		if v ~= nil and not IsMasked(v) then FromCameraPage("user", v, true) end
	end,
	SET_PASSWORD = function(p)
		local v = FirstParam(p, "PASSWORD", "VALUE")
		if v ~= nil and v ~= "" and not IsMasked(v) then FromCameraPage("pass", MaybeBase64Decode(v), true) end
	end,
	PAN_LEFT = function() PtzContinuous(-1, 0, 0) end,
	PAN_RIGHT = function() PtzContinuous(1, 0, 0) end,
	TILT_UP = function() PtzContinuous(0, 1, 0) end,
	TILT_DOWN = function() PtzContinuous(0, -1, 0) end,
	ZOOM_IN = function() PtzContinuous(0, 0, 1) end,
	ZOOM_OUT = function() PtzContinuous(0, 0, -1) end,
	HOME = function() PtzHome() end,
	PRESET = function(p) PtzGotoPreset(FirstParam(p, "INDEX", "PRESET", "ID")) end,
	SELECT_PRESET = function(p) PtzGotoPreset(FirstParam(p, "ID", "INDEX", "PRESET")) end,
}

--[[=============================================================================
    DriverWorks entry points
===============================================================================]]
local VARIABLES = {
	{ "ONLINE", "0", "BOOL" },
	{ "ALERTS_ENABLED", "1", "BOOL" },
	{ "ALERT_ACTIVE", "0", "BOOL" },
	{ "MOTION", "0", "BOOL" },
	{ "PERSON", "0", "BOOL" },
	{ "VEHICLE", "0", "BOOL" },
	{ "LINE_CROSSING", "0", "BOOL" },
	{ "INTRUSION", "0", "BOOL" },
	{ "TAMPER", "0", "BOOL" },
	{ "ALARM_INPUT", "0", "BOOL" },
	{ "MOTION_DETECTION_ENABLED", "0", "BOOL" },
	{ "LAST_DETECTION", "", "STRING" },
	{ "LAST_ALERT", "", "STRING" },
	{ "LAST_ALERT_TIME", "", "STRING" },
	-- DirectorLink camera agreement v1 (other drivers read these by name). A Hikvision doorbell or
	-- intercom, if ever supported, would set KIND = "doorbell", LAST_RING (ISO 8601 UTC) and fire "Ring".
	{ "DIRECTORLINK_CAMERA", "1", "STRING" },
	{ "DIRECTORLINK_CAMERA_KIND", "camera", "STRING" },
}

-- Written on every start, so they are right after a driver update too
local function SetAgreementVariables()
	SetVar("DIRECTORLINK_CAMERA", "1", true)
	SetVar("DIRECTORLINK_CAMERA_KIND", "camera", true)
end

function OnDriverInit(dit)
	math.randomseed(os.time())
	AddVariables(VARIABLES)
	SetAgreementVariables()
	LoadCfg()
	ApplyConnection()
	gCam.onAuthChange = function() UpdateStatus() end
end

function OnDriverLateInit(dit)
	ApplyLogSettings()
	pcall(function()
		local build = tostring(C4:GetDriverConfigInfo("version") or "")
		UpdateProperty("Driver Version", DRIVER_SEMVER ~= "dev" and (DRIVER_SEMVER .. " (" .. build .. ")") or build)
	end)
	for binding in pairs(CONTACT_BINDINGS) do SendContact(binding, false, true) end
	for _, d in pairs(DETECTIONS) do
		if d.var then SetVar(d.var, false) end
	end
	SetVar("ONLINE", false)
	SetVar("ALERT_ACTIVE", false)
	SetAgreementVariables()

	if dit == "DIT_ADDING" or (DIT_ADDING ~= nil and dit == DIT_ADDING) then
		-- A new camera proxy starts with BASIC / not required; Hikvision needs Digest
		pcall(function()
			C4:SendToProxy(CAMERA_PROXY, "PROPERTY_DEFAULTS", {
				HTTP_PORT = "80", RTSP_PORT = "554", AUTHENTICATION_REQUIRED = "true", AUTHENTICATION_TYPE = "DIGEST",
			}, "NOTIFY")
		end)
	end

	SyncFromCameraPage()
	ApplyConnection()
	SaveCfg()
	SetAttention("proxy", nil, true) -- also hides the empty Attention line
	UpdateHubProperty()
	AlertsChanged("startup")
	SendExtrasSetup()
	UpdateExtras()
	UpdateStatus()
	if gCfg.hubId then ReportToHub(true) end
	SetTimer("HEALTH", HEALTH_INTERVAL_MS, HealthCheck, true)
	SetTimer("WATCHDOG", WATCHDOG_INTERVAL_MS, StreamWatchdog, true)
	if CameraEnabled() then ScheduleRefresh(3000) end
end

function OnDriverDestroyed()
	Stream_Stop()
	KillAllTimers()
end

function OnPropertyChanged(name)
	LogDebug("Property changed: %s = %s", name, Properties[name])
	if name == "Log Level" then
		ApplyLogSettings()
	elseif name == "Channel" then
		gInfo.streams = {}
		ScheduleRefresh(1000)
	elseif name == "Event Monitoring" then
		if EventsEnabled() then gStream.fails = 0; Stream_Start() else Stream_Stop(); EndAllDetections() end
		UpdateStatus()
	elseif name == "Alerts" then
		if gCfg.snoozeUntil ~= 0 then gCfg.snoozeUntil = 0; SaveCfg() end
		AlertsChanged("Composer")
	elseif name == "Alert On" then
		UpdateExtras()
	elseif name == "Contact State When Active" then
		for binding in pairs(CONTACT_BINDINGS) do SendContact(binding, ContactActive(binding)) end
	elseif name == "Camera Enabled" then
		EnabledChanged()
	elseif name == "Video Quality" then
		pcall(function() C4:SendToProxy(CAMERA_PROXY, "DYNAMIC_URLS_CHANGED", {}, "NOTIFY") end)
	end
end

function ReceivedFromProxy(idBinding, strCommand, tParams)
	tParams = tParams or {}
	if LOG_LEVEL >= 4 then
		local parts = {}
		for k, v in pairs(tParams) do
			parts[#parts + 1] = tostring(k) .. "=" .. (string.find(string.upper(tostring(k)), "PASSWORD", 1, true) and "***" or tostring(v))
		end
		LogDebug("ReceivedFromProxy(%s, %s, {%s})", idBinding, strCommand, table.concat(parts, ", "))
	end

	if CONTACT_BINDINGS[idBinding] then
		if strCommand == "GET_STATE" then SendContact(idBinding, ContactActive(idBinding), true) end
		return
	end

	if UI_REQ[strCommand] then
		local ok, res = pcall(UI_REQ[strCommand], tParams)
		if ok then return res end
		LogError("%s failed: %s", strCommand, res)
		return
	end

	if EXTRAS_COMMANDS[strCommand] then
		local id = EXTRAS_IDS[strCommand]
		local value = tParams.VALUE or tParams.value or (id and tParams[id])
		local ok, err = pcall(EXTRAS_COMMANDS[strCommand], value)
		if not ok then
			LogError("%s failed: %s", strCommand, err)
			UpdateExtras()
		end
		return
	end

	local handler = PRX_CMD[strCommand]
	if handler then
		local ok, err = pcall(handler, tParams)
		if not ok then LogError("Proxy command %s failed: %s", strCommand, err) end
	end
end

function UIRequest(strCommand, tParams)
	local handler = UI_REQ[strCommand]
	if handler then
		local ok, res = pcall(handler, tParams or {})
		if ok then return res end
		LogError("UIRequest %s failed: %s", strCommand, res)
	end
	return ""
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
		if string.sub(strCommand, 1, 3) ~= "DL_" then LogInfo("Command %s", strCommand) end
		local ok, err = pcall(cmd, tParams)
		if not ok then LogError("Command %s failed: %s", strCommand, err) end
	end
end

function TestCondition(name, tParams)
	tParams = tParams or {}
	if name == "CAMERA_ONLINE" then return TestBool(gState.online == true, tParams, "Online")
	elseif name == "ALERTS_ENABLED" then return TestBool(AlertsEnabled(), tParams, "On")
	elseif name == "ALERT_ACTIVE" then return TestBool(gState.alertActive, tParams, "Active")
	elseif name == "MOTION_ACTIVE" then return TestBool(IsDetectionActive("Motion"), tParams, "Active")
	elseif name == "DETECTION_ACTIVE" then
		local active = IsDetectionActive(tostring(tParams.VALUE or ""))
		if tParams.LOGIC == "NOT_EQUAL" then return not active end
		return active
	elseif name == "LAST_ALERT" then return TestEquals(gState.lastAlert, tParams)
	end
	return false
end

-- Notification attachments
function GetNotificationAttachmentURL()
	return TargetBaseUrl(gCam, true) .. "/" .. NotificationSnapshotPath()
end

function GetNotificationAttachmentBytes()
	if gState.eventSnapshot then return C4:Base64Encode(gState.eventSnapshot) end
	return ""
end

function FinishedWithNotificationAttachment()
end
