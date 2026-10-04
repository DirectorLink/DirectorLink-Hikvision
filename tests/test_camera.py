"""Camera driver tests (offline).   python tests/test_camera.py"""
import base64
import hashlib
import re
import xml.etree.ElementTree as ET

from harness import Driver, check, finish

NS = 'xmlns="http://www.hikvision.com/ver20/XMLSchema"'
USER, PASS = "admin", "Secr3t!pw"
REALM, NONCE = "IP Camera(T1)", "4e6f6e6365303031"


def md5(s):
    return hashlib.md5(s.encode()).hexdigest()


def digest_ok(method, auth, password=PASS):
    if not auth or not auth.startswith("Digest "):
        return False
    f = dict(re.findall(r'(\w+)="?([^",]+)"?', auth[7:]))
    ha1 = md5(f"{f['username']}:{f['realm']}:{password}")
    ha2 = md5(f"{method}:{f['uri']}")
    return f["response"] == md5(f"{ha1}:{f['nonce']}:{f['nc']}:{f['cnonce']}:{f['qop']}:{ha2}")


def jpeg(w, h, pad=0):
    """Smallest JPEG the driver can measure: SOI, APP0, SOF0 (dimensions), padding, EOI."""
    return (b"\xff\xd8" + b"\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00"
            + b"\xff\xc0\x00\x11\x08" + h.to_bytes(2, "big") + w.to_bytes(2, "big") + b"\x03\x01\x22\x00\x02\x11\x01\x03\x11\x01"
            + b"\x00" * pad + b"\xff\xd9")


def camera(password=PASS, rtsp=10554, sub="H.264", sub_picture=True, put_ok=True, resize=None):
    """Responder playing a Digest-protected camera (main H.265, sub H.264 unless told otherwise)."""
    calls = {"n": 0, "sub": sub, "put": None}

    def respond(method, url, headers, body):
        calls["n"] += 1
        path = url.split("192.168.50.81", 1)[-1]
        challenge = {"WWW-Authenticate": f'Digest realm="{REALM}", qop="auth", nonce="{NONCE}", stale="FALSE"'}
        if not digest_ok(method, headers.get("Authorization"), password):
            return 401, challenge, "<html>401</html>"
        if path == "/ISAPI/Streaming/channels/102" and method == "GET":
            prof = "H265Profile" if calls["sub"] == "H.265" else "H264Profile"
            return 200, {}, (f"<StreamingChannel {NS}><id>102</id><channelName>Garden</channelName><enabled>true</enabled><Video><enabled>true</enabled>"
                             f"<videoCodecType>{calls['sub']}</videoCodecType><videoResolutionWidth>640</videoResolutionWidth><videoResolutionHeight>360</videoResolutionHeight>"
                             f"<maxFrameRate>1500</maxFrameRate><{prof}>Main</{prof}><SmartCodec><enabled>true</enabled></SmartCodec></Video></StreamingChannel>")
        if path == "/ISAPI/Streaming/channels/102" and method == "PUT" and not put_ok:
            return 400, {}, f"<ResponseStatus {NS}><statusCode>4</statusCode><subStatusCode>badParameters</subStatusCode></ResponseStatus>"
        if path == "/ISAPI/Streaming/channels/102" and method == "PUT":
            calls["put"] = body
            calls["sub"] = re.search(r"<videoCodecType>([^<]*)</videoCodecType>", body).group(1)
            return 200, {}, f"<ResponseStatus {NS}><statusCode>1</statusCode><statusString>OK</statusString></ResponseStatus>"
        if "/picture?" in path and resize == "scale":
            q = dict(re.findall(r"(\w+)=(\d+)", path.split("?", 1)[1]))
            w, h = int(q["videoResolutionWidth"]), int(q["videoResolutionHeight"])
            return 200, {}, jpeg(w, h, pad=w * h // 100)
        if "/picture?" in path and resize == "ignore":
            return 200, {}, jpeg(3840, 2160, pad=80000)
        if path.endswith("/picture") and resize:
            return 200, {}, (jpeg(3840, 2160, pad=80000) if "/101/" in path else jpeg(640, 360, pad=2300))
        if path == "/ISAPI/Streaming/channels/102/picture" and not sub_picture:
            return 503, {}, f"<ResponseStatus {NS}><statusCode>3</statusCode><subStatusCode>deviceBusy</subStatusCode></ResponseStatus>"
        if path == "/ISAPI/System/deviceInfo":
            return 200, {}, f"<DeviceInfo {NS}><deviceName>Garden</deviceName><model>DS-2CD2087G2-L</model><firmwareVersion>V5.7.15</firmwareVersion><firmwareReleasedDate>build 240201</firmwareReleasedDate><deviceType>IPCamera</deviceType></DeviceInfo>"
        if path == "/ISAPI/Streaming/channels":
            return 200, {}, (f"<StreamingChannelList {NS}>"
                             "<StreamingChannel><id>101</id><enabled>true</enabled><Video><videoCodecType>H.265</videoCodecType><videoResolutionWidth>3840</videoResolutionWidth><videoResolutionHeight>2160</videoResolutionHeight><maxFrameRate>2000</maxFrameRate></Video></StreamingChannel>"
                             "<StreamingChannel><id>102</id><enabled>true</enabled><Video><videoCodecType>" + calls["sub"] + "</videoCodecType><videoResolutionWidth>640</videoResolutionWidth><videoResolutionHeight>360</videoResolutionHeight><maxFrameRate>1500</maxFrameRate></Video></StreamingChannel>"
                             "</StreamingChannelList>")
        if path.endswith("/picture"):
            return 200, {}, b"\xff\xd8\xff\xe0JPEGDATA\xff\xd9"
        if path == "/ISAPI/Event/triggers":
            return 200, {}, (f"<EventTriggerList {NS}>"
                             "<EventTrigger><eventType>VMD</eventType><videoInputChannelID>1</videoInputChannelID><EventTriggerNotificationList><EventTriggerNotification><notificationMethod>center</notificationMethod></EventTriggerNotification></EventTriggerNotificationList></EventTrigger>"
                             "<EventTrigger><eventType>linedetection</eventType><videoInputChannelID>1</videoInputChannelID><EventTriggerNotificationList><EventTriggerNotification><notificationMethod>center</notificationMethod></EventTriggerNotification></EventTriggerNotificationList></EventTrigger>"
                             "<EventTrigger><eventType>fielddetection</eventType><videoInputChannelID>1</videoInputChannelID><EventTriggerNotificationList/></EventTrigger>"
                             "<EventTrigger><eventType>diskfull</eventType><EventTriggerNotificationList><EventTriggerNotification><notificationMethod>center</notificationMethod></EventTriggerNotification></EventTriggerNotificationList></EventTrigger>"
                             "</EventTriggerList>")
        if path == "/ISAPI/Security/adminAccesses":
            return 200, {}, f"<AdminAccessProtocolList {NS}><AdminAccessProtocol><protocol>RTSP</protocol><portNo>{rtsp}</portNo></AdminAccessProtocol></AdminAccessProtocolList>"
        if path.endswith("/motionDetection"):
            return 200, {}, f"<MotionDetection {NS}><enabled>true</enabled></MotionDetection>"
        if path.endswith("/IrcutFilter"):
            return 200, {}, f"<IrcutFilter {NS}><IrcutFilterType>auto</IrcutFilterType></IrcutFilter>"
        if path.endswith("/supplementLight"):
            return 200, {}, f"<SupplementLight {NS}><supplementLightMode>colorVuWhiteLight</supplementLightMode></SupplementLight>"
        return 404, {}, f"<ResponseStatus {NS}><statusCode>4</statusCode><subStatusCode>notSupport</subStatusCode></ResponseStatus>"

    respond.calls = calls
    return respond


def alert(etype, state="active", ch=1, target=None, version="2.0", extra=""):
    tgt = f"<DetectionRegionList><DetectionRegionEntry><detectionTarget>{target}</detectionTarget></DetectionRegionEntry></DetectionRegionList>" if target else ""
    return (f'<EventNotificationAlert version="{version}" {NS}><channelID>{ch}</channelID><eventType>{etype}</eventType>'
            f"<eventState>{state}</eventState>{tgt}{extra}<channelName>Cam & 1</channelName></EventNotificationAlert>")


def started(responder=None, props=""):
    d = Driver("camera", responder)
    if props:
        d.run(f'PROXY_PROPS = "{props}"')
    d.call("OnDriverInit", "DIT_ADDING")
    d.run("OnDriverLateInit('DIT_ADDING')")
    return d


# ---------------------------------------------------------------- new camera, nothing configured
d = started(props="<camera_properties><address>127.0.0.1</address><http_port>80</http_port><authentication_type>BASIC</authentication_type><username>******</username><password>******</password></camera_properties>")
check(d.prop("Status").startswith("Setup: enter the Address"), f"new camera asks for the address ({d.prop('Status')})")
check(any(c == "PROPERTY_DEFAULTS" and p.get("AUTHENTICATION_TYPE") == "DIGEST" for _, c, p in d.proxy()), "first add sends Digest defaults to the camera proxy")
check(d.g.ATTRIBS["Attention"] == 1, "Attention property hidden when nothing needs attention")
check(d.g.PERSIST["DL_PASS"] is None, "no encrypted empty password stored")
d.call("ReceivedFromProxy", 5001, "SET_ADDRESS", d.table({"ADDRESS": "localhost"}))
check(d.g.gCam.host == "", "loopback address ignored")

# ---------------------------------------------------------------- managed by the hub: one message configures everything
resp = camera()
d = started(resp)
d.clear()
d.call("ExecuteCommand", "DL_CONFIGURE", d.table({"HUB_ID": "500", "HUB_ALERTS": "1", "ADDRESS": "192.168.50.81", "HTTP_PORT": "80",
                                                  "CHANNEL": "1", "USERNAME": USER, "PASSWORD": PASS, "NAME": "Garden", "RENAME": "1",
                                                  "ALERT_ON": "People and vehicles"}))
sets = {c: (p, log) for _, c, p, log in d.device_cmds(device=901)}
check(sets.get("SET_ADDRESS", ({},))[0].get("ADDRESS") == "192.168.50.81", "hub config writes the IP into the camera Properties page")
check(sets.get("SET_AUTHENTICATION_TYPE", ({},))[0].get("TYPE") == "DIGEST" and sets.get("SET_AUTHENTICATION_REQUIRED", ({},))[0].get("REQUIRED") == "True", "... Digest + authentication required")
check(sets.get("SET_USERNAME", ({},))[0].get("USERNAME") == USER and sets.get("SET_PASSWORD", ({},))[0].get("PASSWORD") == PASS, "... username and password")
check(sets.get("SET_PASSWORD", (None, True))[1] is False, "... the password command is not logged by Director")
check([tuple(r.values()) for r in d.g.RENAMED.values()] == [(901, "Garden")], "camera device renamed to the NVR name")
d.g.DISPLAY_NAMES[901] = "Garden"
d.run("RENAMED = {}")
d.call("ExecuteCommand", "DL_CONFIGURE", d.table({"HUB_ID": "500", "NAME": "Garden", "RENAME": "1"}))
check(len(d.g.RENAMED) == 0, "no rename when the device already has that name")
check(d.prop("Alert On") == "People and vehicles", "hub's default Alert On applied")
check(d.g.PERSIST["DL_CFG"]["host"] == "192.168.50.81" and d.g.PERSIST["DL_CFG"]["user"] == USER and d.g.PERSIST["DL_PASS"] == PASS
      and d.g.PERSIST["DL_CFG"]["hubId"] == 500, "address, login and hub kept by the driver (password encrypted)")
check(d.prop("Managed By") == "Hub 500", f"Managed By shows the hub by name ({d.prop('Managed By')})")

# refresh against the camera
d.clear()
d.timers()   # REFRESH (and proxy verification)
log = list(d.g.HTTP_LOG.values())
first = log[0]
check(first["auth"] is None and log[1]["auth"] and log[1]["auth"].startswith("Digest "), "Digest: challenge, then authorised retry")
check(all(e["ua"] == "DirectorLink-Hikvision-Camera/test" for e in log), "every request carries the User-Agent DirectorLink-Hikvision-Camera/<version>")
check(d.prop("Camera").startswith("DS-2CD2087G2-L"), f"camera model read ({d.prop('Camera')})")
check("Main H.265 3840x2160" in d.prop("Video") and "Sub H.264 640x360" in d.prop("Video"), f"streams read ({d.prop('Video')})")
check(d.prop("Events") == "Motion, Line Crossing", f"events that notify Control4 ({d.prop('Events')})")
check(d.prop("Status").startswith("Online"), f"status online ({d.prop('Status')})")
rtsp = [p for _, c, p, _ in d.device_cmds("SET_RTSP_PORT", 901)]
check(rtsp and rtsp[-1].get("PORT") == "10554" and d.g.PERSIST["DL_CFG"]["rtspPort"] == 10554, "camera's RTSP port (10554) corrected on the camera page")
check("diskfull" not in d.prop("Events"), "device faults are not listed as detections")
q = d.call("UIRequest", "GET_RTSP_H264_QUERY_STRING", d.table({"SIZE_X": "1920"}))
check(q == "<rtsp_h264_query_string>Streaming/Channels/102</rtsp_h264_query_string>", f"H.265 main stream skipped: full screen uses H.264 sub ({q})")
q = d.call("UIRequest", "GET_SNAPSHOT_QUERY_STRING", d.table({"SIZE_X": "320"}))
check(q == "<snapshot_query_string>ISAPI/Streaming/channels/102/picture</snapshot_query_string>", "small snapshot from the sub stream")
d.g.Properties["Video Quality"] = "High"
q = d.call("UIRequest", "GET_SNAPSHOT_QUERY_STRING", d.table({"SIZE_X": "320"}))
check(q.endswith("channels/101/picture</snapshot_query_string>"), "Video Quality High forces the main stream")
d.g.Properties["Video Quality"] = "Auto"
setup = [p for _, c, p in d.proxy("EXTRAS_SETUP_CHANGED")]
root = ET.fromstring(setup[-1]["XML"])
ids = {o.get("id"): o for o in root.iter("object")}
check(set(ids) == {"alerts", "alerton", "snooze", "motion", "daynight", "light", "reboot"}, f"Extras objects ({sorted(ids)})")
check(len(ids["light"].findall("list/item")) == 4 and ids["snooze"].findtext("buttontext") == "Snooze", "Extras: light list (camera has a supplement light) and snooze button")
state = [p for _, c, p in d.proxy("EXTRAS_STATE_CHANGED")][-1]["XML"]
check('id="daynight" value="auto"' in state and 'id="light" value="colorVuWhiteLight"' in state and 'id="motion" value="True"' in state, "Extras state reflects the camera")
hub = d.device_cmds("DL_CAMERA_STATUS", 500)
check(hub and hub[-1][2].get("ONLINE") == "1" and hub[-1][2].get("NAME") == "Garden" and hub[-1][2].get("DISABLED") == "0"
      and hub[-1][2].get("H264") == "1", "status reported to the hub")

# ---------------------------------------------------------------- detections and alerts
d.clear()
d.call("HandleAlert", alert("VMD"))
check(d.events() == ["Motion Detected"], f"People and vehicles: plain motion runs automations but raises no Alert ({d.events()})")
d.clear()
d.call("HandleAlert", alert("linedetection", target="human"))
check(d.events() == ["Line Crossing", "Person Detected", "Alert"], f"person target raises the Alert ({d.events()})")
check(d.var("ALERT_ACTIVE") == "1" and d.var("LAST_ALERT") == "Person" and d.var("PERSON") == "1", "alert variables")
check((100, "CLOSED", {}) in d.proxy() and (102, "CLOSED", {}) in d.proxy(), "Alert and Person contacts closed")
check(len(d.g.HISTORY) == 1 and d.device_cmds("DL_CAMERA_ALERT", 500)[0][2]["TYPE"] == "Person", "alert recorded in History and sent to the hub")
d.clear()
d.call("HandleAlert", alert("linedetection", target="human"))
check("Alert" not in d.events() and "Person Detected" not in d.events(), "repeat within the hold time does not re-fire")
d.timers()
check(d.var("ALERT_ACTIVE") == "0" and d.var("PERSON") == "0", "hold time ends the alert and detections")

d.g.Properties["Alert On"] = "Any detection"
d.clear()
d.call("ExecuteCommand", "DL_HUB_ALERTS", d.table({"HUB_ID": "500", "ENABLED": "0"}))
check("Alerts Off" in d.events() and d.var("ALERTS_ENABLED") == "0", "hub master switch turns this camera's alerts off")
d.clear()
d.call("HandleAlert", alert("VMD"))
check(d.events() == ["Motion Detected"], "alerts off: automation event still fires, no Alert")
d.timers()
d.call("ExecuteCommand", "DL_HUB_ALERTS", d.table({"HUB_ID": "500", "ENABLED": "1"}))
d.clear()
d.call("ReceivedFromProxy", 5001, "EXTRAS_SNOOZE", d.table({"id": "snooze"}))
check("Alerts Off" in d.events() and d.g.PERSIST["DL_CFG"]["snoozeUntil"] > 0, "Snooze button pauses alerts (persisted)")
check("snoozed until" in d.prop("Status"), f"status shows the snooze ({d.prop('Status')})")
d.clear()
d.call("ReceivedFromProxy", 5001, "EXTRAS_ALERTS", d.table({"value": "True"}))
check("Alerts On" in d.events() and d.var("ALERTS_ENABLED") == "1", "Alerts checkbox resumes alerts and clears the snooze")
check(d.call("TestCondition", "ALERTS_ENABLED", d.table({"VALUE": "On"})) is True, "conditional Alerts are On")

# Extras commands always answer (UI reverts after 10 s otherwise)
d.clear()
d.call("ReceivedFromProxy", 5001, "EXTRAS_DAY_NIGHT", d.table({"daynight": "night"}))
d.call("ReceivedFromProxy", 5001, "EXTRAS_LIGHT", d.table({"value": "bogus"}))
check(len(d.proxy("EXTRAS_STATE_CHANGED")) == 2, "each Extras command answered with a state update")
check(d.call("ReceivedFromProxy", 102, "GET_STATE", d.table({})) is None and (102, "STATE_OPENED", {}) in d.proxy(), "contact GET_STATE answered")

# ---------------------------------------------------------------- wrong password: one failed login, then stop
bad = camera(password="different")
d = started(bad)
d.call("ExecuteCommand", "DL_CONFIGURE", d.table({"HUB_ID": "500", "ADDRESS": "192.168.50.81", "USERNAME": USER, "PASSWORD": PASS}))
d.clear()
d.timers()
attempts = [e for e in d.g.HTTP_LOG.values() if e["auth"]]
check(len(attempts) == 1, f"wrong password costs exactly one failed login ({len(attempts)})")
check(d.prop("Status").startswith("Login failed"), f"status says login failed ({d.prop('Status')})")
d.clear()
d.call("ExecuteCommand", "SET_MOTION_DETECTION", d.table({"State": "Off"}))
check(len(d.g.HTTP_LOG) == 0, "no further login attempts until the login changes")

# ---------------------------------------------------------------- stream parsing + credentials from the proxy page
d = Driver("camera")
payload = b""
for x in (alert("videoloss", "inactive"), alert("VMD"), alert("linedetection", target="human")):
    body = x.encode()
    payload += b"--boundary\r\nContent-Type: application/xml\r\nContent-Length: %d\r\n\r\n" % len(body) + body + b"\r\n"
    payload += b"--boundary\r\nContent-Type: image/jpeg\r\nContent-Length: 6\r\n\r\n\xff\xd8<Even\xff\xd9\r\n"
chunked, pos, sizes, i = b"", 0, [7, 1, 300, 13, 64, 2], 0
while pos < len(payload):
    n = sizes[i % len(sizes)]; i += 1
    chunked += b"%x\r\n" % len(payload[pos:pos + n]) + payload[pos:pos + n] + b"\r\n"; pos += n
d.run("CAPTURED = {}; ST = { cbuf = '', xbuf = '' }")
feed = d.lua.eval("function(data) Stream_Feed(ST, Dechunk(ST, data), function(x) CAPTURED[#CAPTURED + 1] = x end) end")
for k in range(0, len(chunked), 5):
    feed(chunked[k:k + 5].decode("latin-1"))
check(len(list(d.g.CAPTURED.values())) == 3, "3 alerts recovered from a chunked multipart stream split every 5 bytes")

d = started()
d.call("ReceivedFromProxy", 5001, "SET_PASSWORD", d.table({"PASSWORD": "******"}))
d.call("ReceivedFromProxy", 5001, "SET_PASSWORD", d.table({"PASSWORD": base64.b64encode(b"Pa55word!x").decode()}))
check(d.g.PERSIST["DL_PASS"] == "Pa55word!x", "camera page password: masked ignored, Base64 decoded, stored encrypted")

# ---------------------------------------------------------------- the camera page is the one place to edit
page = ("<camera_properties><address>192.168.50.81</address><http_port>80</http_port><https_port>443</https_port><use_https>False</use_https>"
        "<rtsp_port>10554</rtsp_port><username>******</username><password>******</password></camera_properties>")
d = started(camera(), props=page)
check(d.g.gCam.host == "192.168.50.81" and d.prop("Status").startswith("Setup: enter the Username"),
      f"address taken from the camera page; the login is still needed ({d.prop('Status')})")
d.clear()
d.call("ReceivedFromProxy", 5001, "SET_USERNAME", d.table({"USERNAME": USER}))
d.call("ReceivedFromProxy", 5001, "SET_PASSWORD", d.table({"PASSWORD": base64.b64encode(PASS.encode()).decode()}))
d.timers()
check(d.prop("Status").startswith("Online"), f"login entered on the camera page: online ({d.prop('Status')})")
check(d.g.PERSIST["DL_CFG"]["user"] == USER and d.g.PERSIST["DL_PASS"] == PASS, "the driver keeps its own copy of the login (the page never shows it back)")
check(not d.device_cmds("SET_ADDRESS", 901), "nothing is written back to the page")
d.run(f'PROXY_PROPS = "{page.replace("<http_port>80<", "<http_port>8080<")}"')
d.call("ExecuteCommand", "LUA_ACTION", d.table({"ACTION": "Reconnect"}))
d.timers()
check(d.g.gCam.port == 8080 and d.g.gCam.user == USER and d.g.gCam["pass"] == PASS, "Reconnect re-reads the camera page; the stored login stays")
d.call("ReceivedFromProxy", 5001, "SET_USE_HTTPS", d.table({"USE_HTTPS": "True"}))
check(d.g.gCam.https and d.g.gCam.port == 443, "Use HTTPS on the camera page switches to the HTTPS port")

# ---------------------------------------------------------------- a hub camera without a login asks the hub for it
d = Driver("camera", camera())
d.run('PERSIST["DL_CFG"] = { name = "Garden", hubId = 500, hubAlerts = true, snoozeUntil = 0 }')
d.run(f'PROXY_PROPS = "{page}"')
d.call("OnDriverInit", "DIT_UPDATING")
d.run("OnDriverLateInit('DIT_UPDATING')")
st = d.device_cmds("DL_CAMERA_STATUS", 500)
check(st and st[-1][2].get("NEED_LOGIN") == "1" and d.prop("Status").startswith("Waiting for the camera login"),
      f"no login: the camera tells the hub ({d.prop('Status')})")
d.call("ExecuteCommand", "DL_CONFIGURE", d.table({"HUB_ID": "500", "ADDRESS": "192.168.50.81", "HTTP_PORT": "80", "CHANNEL": "1",
                                                  "USERNAME": USER, "PASSWORD": PASS, "NAME": "Garden"}))
d.timers()
check(d.prop("Status").startswith("Online") and d.device_cmds("DL_CAMERA_STATUS", 500)[-1][2].get("NEED_LOGIN") == "0",
      f"online once the hub sends the login ({d.prop('Status')})")

# ---------------------------------------------------------------- Camera Enabled = No
d.clear()
d.g.Properties["Camera Enabled"] = "No"
d.call("OnPropertyChanged", "Camera Enabled")
check(d.prop("Status").startswith("Disabled"), f"disabled status ({d.prop('Status')})")
hub = d.device_cmds("DL_CAMERA_STATUS", 500)
check(hub and hub[-1][2].get("DISABLED") == "1" and hub[-1][2].get("ONLINE") == "", "hub told the camera is disabled")
d.clear()
d.run("for _, t in ipairs(TIMERS) do if t.active then t.fn(t) end end")  # health check, watchdog
d.call("ExecuteCommand", "LUA_ACTION", d.table({"ACTION": "Reconnect"}))
d.timers()
d.call("HandleAlert", alert("VMD"))
check(len(d.g.HTTP_LOG) == 0, "disabled: no requests to the camera, even on Reconnect")
check("Camera Offline" not in d.events(), "disabled: no offline event")
d.g.Properties["Camera Enabled"] = "Yes"
d.call("OnPropertyChanged", "Camera Enabled")
d.timers()
check(d.prop("Status").startswith("Online"), f"enabled again: back online ({d.prop('Status')})")

# ---------------------------------------------------------------- H.265 sub stream: snapshots and the H.264 fix
resp = camera(sub="H.265", sub_picture=False)
d = started(resp)
d.call("ExecuteCommand", "DL_CONFIGURE", d.table({"HUB_ID": "500", "ADDRESS": "192.168.50.81", "USERNAME": USER, "PASSWORD": PASS}))
d.timers()
check("Set Sub Stream To H.264" in d.prop("Attention"), f"no H.264 stream: Attention points to the action ({d.prop('Attention')})")
check(d.device_cmds("DL_CAMERA_STATUS", 500)[-1][2].get("H264") == "0", "hub told the camera has no H.264 video")
q = d.call("UIRequest", "GET_SNAPSHOT_QUERY_STRING", d.table({"SIZE_X": "320"}))
check(q.endswith("channels/101/picture</snapshot_query_string>"), f"sub stream gives no snapshot: tiles use the main stream ({q})")
check("snapshot" not in d.prop("Attention"), "a working main-stream snapshot needs no attention")
d.clear()
d.call("ExecuteCommand", "LUA_ACTION", d.table({"ACTION": "SubStreamH264"}))
put = resp.calls["put"] or ""
check("<videoCodecType>H.264</videoCodecType>" in put and "<H264Profile>Main</H264Profile>" in put and "H265Profile" not in put
      and "<SmartCodec><enabled>false</enabled></SmartCodec>" in put and "<channelName>Garden</channelName>" in put,
      "sub stream switched to H.264 (profile and Smart Codec adjusted, rest of the settings kept)")
d.timers()
check("H.264" not in d.prop("Attention") and "Sub H.264" in d.prop("Video"), f"refreshed: video playable ({d.prop('Video')})")
q = d.call("UIRequest", "GET_RTSP_H264_QUERY_STRING", d.table({"SIZE_X": "640"}))
check(q == "<rtsp_h264_query_string>Streaming/Channels/102</rtsp_h264_query_string>", f"touchscreens get the H.264 sub stream ({q})")
d.clear()
d.call("ExecuteCommand", "DL_FIX_SUBSTREAM", d.table({}))
check(not any(e["method"] == "PUT" for e in d.g.HTTP_LOG.values()), "already H.264: nothing written")

# ---------------------------------------------------------------- the hub asks for H.264 when it adds a camera
resp = camera(sub="H.265")
d = started(resp)
d.call("ExecuteCommand", "DL_CONFIGURE", d.table({"HUB_ID": "500", "ADDRESS": "192.168.50.81", "USERNAME": USER, "PASSWORD": PASS,
                                                  "FIX_SUBSTREAM": "1"}))
d.timers(); d.timers()
check("<videoCodecType>H.264</videoCodecType>" in (resp.calls["put"] or "") and "Sub H.264" in d.prop("Video")
      and "H.264" not in d.prop("Attention"), f"sub stream switched automatically, video playable ({d.prop('Video')})")

resp = camera(sub="H.265", put_ok=False)
d = started(resp)
d.call("ExecuteCommand", "DL_CONFIGURE", d.table({"HUB_ID": "500", "ADDRESS": "192.168.50.81", "USERNAME": USER, "PASSWORD": PASS,
                                                  "FIX_SUBSTREAM": "1"}))
d.timers(); d.timers()
check("refused H.264" in d.prop("Attention") and "badParameters" in d.prop("Attention") and "web page" in d.prop("Attention"),
      f"a camera that refuses H.264: Attention says why and where to change it ({d.prop('Attention')})")

# ---------------------------------------------------------------- an NVR channel whose camera is offline
nvr_state = {"online": "false"}


def nvr(method, url, headers, body):
    path = url.split("192.168.50.80:8080", 1)[-1]
    if not digest_ok(method, headers.get("Authorization")):
        return 401, {"WWW-Authenticate": f'Digest realm="{REALM}", qop="auth", nonce="{NONCE}", stale="FALSE"'}, ""
    if path == "/ISAPI/System/deviceInfo":
        return 200, {}, f"<DeviceInfo {NS}><deviceName>Recorder</deviceName><model>DS-7608NXI-K2</model><firmwareVersion>V4.83</firmwareVersion><deviceType>NVR</deviceType></DeviceInfo>"
    if path == "/ISAPI/ContentMgmt/InputProxy/channels/status":
        return 200, {}, (f"<InputProxyChannelStatusList {NS}>"
                         "<InputProxyChannelStatus><id>1</id><online>true</online></InputProxyChannelStatus>"
                         f"<InputProxyChannelStatus><id>3</id><online>{nvr_state['online']}</online></InputProxyChannelStatus>"
                         "</InputProxyChannelStatusList>")
    if path.endswith("/picture"):
        return 503, {}, f"<ResponseStatus {NS}><statusCode>3</statusCode><subStatusCode>serviceUnavailable</subStatusCode></ResponseStatus>"
    if path == "/ISAPI/Streaming/channels/302" and method == "GET":
        return 200, {}, (f"<StreamingChannel {NS}><id>302</id><Video><videoCodecType>H.265</videoCodecType><videoResolutionWidth>640</videoResolutionWidth>"
                         "<videoResolutionHeight>360</videoResolutionHeight><H265Profile>Main</H265Profile></Video></StreamingChannel>")
    if path == "/ISAPI/Streaming/channels/302" and method == "PUT":
        nvr_state["put"] = body
        return 200, {}, f"<ResponseStatus {NS}><statusCode>1</statusCode></ResponseStatus>"
    return 404, {}, f"<ResponseStatus {NS}><statusCode>4</statusCode><subStatusCode>notSupport</subStatusCode></ResponseStatus>"


d = started(nvr)
d.call("ExecuteCommand", "DL_CONFIGURE", d.table({"HUB_ID": "500", "ADDRESS": "192.168.50.80", "HTTP_PORT": "8080", "CHANNEL": "3",
                                                  "USERNAME": USER, "PASSWORD": PASS, "NAME": "Side Gate", "FIX_SUBSTREAM": "1"}))
d.timers(); d.timers()
check("put" not in nvr_state, "H.264 is not attempted while the NVR channel's camera is offline")
check(d.prop("Status") == "Offline - the camera on NVR channel 3 is not connected to the NVR", f"offline NVR channel shown as offline ({d.prop('Status')})")
check("NVR channel 3 is offline" in d.prop("Attention") and "snapshot" not in d.prop("Attention"), f"Attention explains it once ({d.prop('Attention')})")
check(d.device_cmds("DL_CAMERA_STATUS", 500)[-1][2].get("ONLINE") == "0", "the hub is told the camera is offline")
d.clear()
nvr_state["online"] = "true"
d.run("for _, t in ipairs(TIMERS) do if t.active and t.rep then t.fn(t) end end")  # health check
check(d.prop("Status").startswith("Online") and "Camera Online" in d.events() and "is offline" not in d.prop("Attention"),
      f"the camera reconnects to the NVR: online again ({d.prop('Status')})")
d.timers()
check("<videoCodecType>H.264</videoCodecType>" in nvr_state.get("put", ""), "the waiting H.264 switch runs once the camera is back")

# ---------------------------------------------------------------- snapshots sized to the request
d = started(camera(resize="scale"))
d.call("ExecuteCommand", "DL_CONFIGURE", d.table({"HUB_ID": "500", "ADDRESS": "192.168.50.81", "USERNAME": USER, "PASSWORD": PASS}))
d.timers()
check(tuple(d.call("JpegSize", jpeg(1280, 720))) == (1280, 720), "JPEG dimensions read from the frame header")
q = d.call("UIRequest", "GET_SNAPSHOT_QUERY_STRING", d.table({"SIZE_X": "320", "SIZE_Y": "180"}))
check(q == "<snapshot_query_string>ISAPI/Streaming/channels/101/picture?videoResolutionWidth=320&amp;videoResolutionHeight=180</snapshot_query_string>",
      f"a 320 px tile gets a 320x180 picture from the camera ({q})")
q = d.call("UIRequest", "GET_SNAPSHOT_QUERY_STRING", d.table({"SIZE_X": "1920", "SIZE_Y": "1080"}))
check(q == "<snapshot_query_string>ISAPI/Streaming/channels/101/picture</snapshot_query_string>", f"full screen gets the whole main picture ({q})")
check(d.call("GetNotificationAttachmentURL").endswith("/ISAPI/Streaming/channels/101/picture?videoResolutionWidth=1280&videoResolutionHeight=720"),
      "notification picture is 1280x720")
check(d.device_cmds("DL_CAMERA_STATUS", 500)[-1][2].get("SNAPSHOT") == "ISAPI/Streaming/channels/101/picture?videoResolutionWidth=1280&videoResolutionHeight=720",
      "the hub is told which picture to attach")

d = started(camera(resize="ignore"))
d.call("ExecuteCommand", "DL_CONFIGURE", d.table({"HUB_ID": "500", "ADDRESS": "192.168.50.81", "USERNAME": USER, "PASSWORD": PASS}))
d.timers()
q = d.call("UIRequest", "GET_SNAPSHOT_QUERY_STRING", d.table({"SIZE_X": "320", "SIZE_Y": "180"}))
check(q == "<snapshot_query_string>ISAPI/Streaming/channels/102/picture</snapshot_query_string>",
      f"a camera that ignores sizes keeps whole stream pictures ({q})")
check(d.call("GetNotificationAttachmentURL").endswith("/ISAPI/Streaming/channels/102/picture"),
      "... and the light sub stream picture for notifications, not the 4K one")

# ---------------------------------------------------------------- requests to one camera run one at a time
d = Driver("camera", camera())
d.run("""
PENDING = {}
local makeUrl = C4.url
function C4:url()
  local x = makeUrl(self)
  local get = x.Get
  function x:Get(url, headers) PENDING[#PENDING + 1] = function() get(self, url, headers) end return self end
  return x
end
T = NewTarget({ host = "192.168.50.81", user = "admin", pass = "x" })
DONE = {}
Isapi(T, "GET", "/a", nil, function(code) DONE[#DONE + 1] = "a:" .. tostring(code) end, { noAuth = true })
Isapi(T, "GET", "/b", nil, function(code) DONE[#DONE + 1] = "b:" .. tostring(code) end, { noAuth = true })
Isapi(T, "GET", "/c", nil, function(code) DONE[#DONE + 1] = "c:" .. tostring(code) end, { noAuth = true })
""")
check(len(d.g.PENDING) == 1, "second request waits while the first is in flight")
d.run("table.remove(PENDING, 1)()")
check(list(d.g.DONE.values()) == ["a:401"] and len(d.g.PENDING) == 1, "the next request starts when the first answers")
d.timers()  # the second never answers: the guard timer moves the queue on
check(list(d.g.DONE.values()) == ["a:401", "b:nil"] and len(d.g.PENDING) == 2, "a request that never answers does not block the queue")
d.run("PENDING[1]()")
check(list(d.g.DONE.values()) == ["a:401", "b:nil"], "a late answer after the guard is ignored")
d.run("PENDING[2]()")
check(list(d.g.DONE.values()) == ["a:401", "b:nil", "c:401"], "queue completes in order")

finish()
