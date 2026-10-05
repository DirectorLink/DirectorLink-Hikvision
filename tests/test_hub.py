"""Hub driver tests (offline).   python tests/test_hub.py"""
import hashlib
import re

from harness import Driver, check, finish

NS = 'xmlns="http://www.hikvision.com/ver20/XMLSchema"'
USER, PASS = "admin", "Secr3t!pw"


def md5(s):
    return hashlib.md5(s.encode()).hexdigest()


def digest_ok(method, auth):
    if not auth or not auth.startswith("Digest "):
        return False
    f = dict(re.findall(r'(\w+)="?([^",]+)"?', auth[7:]))
    ha1 = md5(f"{f['username']}:{f['realm']}:{PASS}")
    ha2 = md5(f"{method}:{f['uri']}")
    return f["response"] == md5(f"{ha1}:{f['nonce']}:{f['nc']}:{f['cnonce']}:{f['qop']}:{ha2}")


def probe_match(ip, model, port=80, digital=1, activated="true"):
    return (f'<?xml version="1.0" encoding="UTF-8" ?>\n<ProbeMatch>\n<Uuid>X</Uuid>\n<Types>inquiry</Types>\n<DeviceType>1</DeviceType>\n'
            f"<DeviceDescription>{model}</DeviceDescription>\n<DeviceSN>{model}SN</DeviceSN>\n<CommandPort>8000</CommandPort>\n"
            f"<HttpPort>{port}</HttpPort>\n<MAC>aa-bb-cc-00-00-{ip[-2:]}</MAC>\n<IPv4Address>{ip}</IPv4Address>\n<AnalogChannelNum>0</AnalogChannelNum>\n"
            f"<DigitalChannelNum>{digital}</DigitalChannelNum>\n<SoftwareVersion>V5.7.15</SoftwareVersion>\n<Activated>{activated}</Activated>\n</ProbeMatch>\n")


NVR_STATUS = {"xml": None}
GITHUB = {"calls": 0, "moved": False}


def network(method, url, headers, body):
    if url.startswith("https://api.github.com/"):
        GITHUB["calls"] += 1
        GITHUB["last"] = url
        if GITHUB["moved"] and "/repos/" in url:
            return 301, {"Location": "https://api.github.com/repositories/1403883922/releases/latest"}, ""
        return 200, {}, '{"tag_name": "v9.9.9", "name": "DirectorLink"}'
    if not digest_ok(method, headers.get("Authorization")):
        return 401, {"WWW-Authenticate": 'Digest realm="NVR", qop="auth", nonce="abc123", stale="FALSE"'}, ""
    if url == "http://192.168.50.80:90/ISAPI/ContentMgmt/InputProxy/channels":
        ch = lambda i, name, ip, model: (f"<InputProxyChannel><id>{i}</id><name>{name}</name><sourceInputPortDescriptor>"
                                         f"<ipAddress>{ip}</ipAddress><model>{model}</model></sourceInputPortDescriptor></InputProxyChannel>")
        return 200, {}, (f"<InputProxyChannelList {NS}>" + ch(1, "Garden", "192.168.50.81", "DS-2CD2087G2-L")
                         + ch(2, "Gate", "192.168.50.82", "DS-2CD2347G2H-LISU/SL") + ch(3, "Pool", "192.168.254.3", "DS-2CD2143G2-I")
                         + ch(4, "Camera 04", "192.168.254.4", "DS-2CD1043G0-I") + "</InputProxyChannelList>")
    if url == "http://192.168.50.80:90/ISAPI/ContentMgmt/InputProxy/channels/status" and NVR_STATUS["xml"]:
        return 200, {}, NVR_STATUS["xml"]
    if url.endswith("/ISAPI/System/deviceInfo"):
        return 200, {}, f"<DeviceInfo {NS}><deviceName>IP CAMERA</deviceName><model>X</model></DeviceInfo>"
    if url == "http://192.168.50.83/ISAPI/System/Video/inputs/channels/1":
        return 200, {}, f"<VideoInputChannel {NS}><id>1</id><inputPort>1</inputPort><name>Back Door</name></VideoInputChannel>"
    if url.endswith("/picture"):
        return 200, {}, b"\xff\xd8\xff\xe0SNAP\xff\xd9"
    return 404, {}, ""


def hub(responder=network):
    d = Driver("hub", responder)
    d.g.Properties["Username"] = USER
    d.g.Properties["Password"] = PASS
    d.run("DEVICE_ID = 500")
    d.call("OnDriverInit")
    d.call("OnDriverLateInit")
    return d


def discover(d):
    d.timers(); d.timers()   # let any search already in progress finish
    d.call("StartDiscovery", "test")
    for m in (probe_match("192.168.50.80", "DS-7616NXI-K2(D)", port=90, digital=16), probe_match("192.168.50.81", "DS-2CD2087G2-L"),
              probe_match("192.168.50.82", "DS-2CD2347G2H-LISU/SL"), probe_match("192.168.50.83", "DS-2CD2087G2-L"),
              probe_match("192.168.50.99", "DS-2CD2T47G2-L", activated="false")):
        d.call("HandleSadpData", m)
    d.timers()  # probes + end of the discovery window + NVR channel read


# ---------------------------------------------------------------- search the network
d = hub()
check(d.g.TIMERS is not None and any(t.ms == 5000 for t in d.g.TIMERS.values()), "search scheduled at startup when a login is set")
d.clear()
discover(d)
net = [list(x.values()) for x in d.g.NET.values()]
check(["options", 6100, 37020, "MULTICAST"] == net[1][:4] and ["connect", 6100, 37020, "MULTICAST"] == net[2], "SADP multicast connection on 239.255.255.250:37020")
check(any(x[0] == "send" and "<Types>inquiry</Types>" in x[3] for x in net), "SADP probe sent")
found = d.prop("Found On Network")
check(found == "3 cameras, 1 NVR - 5 not added yet - 1 not activated (activate with Hikvision SADP)", f"found summary ({found})")
check(all(e["ua"] == "DirectorLink-Hikvision/test" for e in d.g.HTTP_LOG.values()) and len(d.g.HTTP_LOG) > 0, "hub requests carry the User-Agent DirectorLink-Hikvision/<version>")
check("New Cameras Found" in d.events(), "New Cameras Found event")
check("run Actions > Add New Cameras" in d.prop("Status"), f"status tells what to do next ({d.prop('Status')})")
cands = d.call("BuildCandidates")[0]
c = [(x.address, x.channel, x.port, x.nvrName, bool(x.viaNvr)) for x in cands.values()]
check(c == [("192.168.50.80", 3, 90, "Pool", True), ("192.168.50.80", 4, 90, None, True),
            ("192.168.50.81", 1, 80, "Garden", False), ("192.168.50.82", 1, 80, "Gate", False), ("192.168.50.83", 1, 80, None, False)],
      f"candidates: direct cameras with NVR names + NVR-only channels; not-activated camera skipped ({c})")

# ---------------------------------------------------------------- add them all
d.run('C4I_BY_NAME["camera.c4i"] = { 300 }; UI_PROPS[300] = "<camera_properties><address>192.168.50.81</address></camera_properties>"')
d.g.DISPLAY_NAMES[300] = "Café Terrace"
d.clear()
d.call("ExecuteCommand", "LUA_ACTION", d.table({"ACTION": "AddCameras"}))
next_id = 1001
for _ in range(5):
    added = list(d.g.ADDED.values())
    a = added[-1]
    a.cb(next_id, d.table({}))
    next_id += 1
    d.timers()
names = [a.name for a in d.g.ADDED.values()]
check(names == ["Pool", "DS-2CD1043G0-I (192.168.50.80 ch4)", "Café Terrace", "Gate", "Back Door"],
      f"names: existing Control4 name > NVR name > on-screen name > model ({names})")
check(all(a.file == "DirectorLink-Hikvision-Camera.c4z" and a.room == 81 for a in d.g.ADDED.values()), "camera driver added to the hub's room")
cfg = {dev: p for dev, cmd, p, log in d.device_cmds("DL_CONFIGURE")}
check(cfg[1003]["ADDRESS"] == "192.168.50.81" and cfg[1003]["CHANNEL"] == "1" and cfg[1003]["NAME"] == "Café Terrace" and cfg[1003]["RENAME"] == "1",
      ".81 configured: address, channel, its Control4 name, rename")
check(cfg[1001]["ADDRESS"] == "192.168.50.80" and cfg[1001]["HTTP_PORT"] == "90" and cfg[1001]["CHANNEL"] == "3", "Pool configured through the NVR (port 90, channel 3)")
check(all(p["USERNAME"] == USER and p["PASSWORD"] == PASS and p["HUB_ID"] == "500" for p in cfg.values()), "one login sent to every camera")
check(all(log is False for _, _, _, log in d.device_cmds("DL_CONFIGURE")), "configuration messages are not logged (they carry the password)")
check(all(p.get("FIX_SUBSTREAM") == "1" for dev, cmd, p, _ in d.device_cmds("DL_CONFIGURE") if p.get("RENAME") == "1"),
      "Sub Stream To H.264 = Automatic: every added camera is asked to switch to H.264")
check(d.prop("Status") == "Added 5 cameras - drag them to their rooms in Composer", f"final status ({d.prop('Status')})")
check(d.prop("Found On Network").startswith("3 cameras, 1 NVR - 0 not added yet"), f"Found On Network updated after adding ({d.prop('Found On Network')})")

# rename after the fact: the Control4 name changed, Update Camera Names follows it
d.g.DISPLAY_NAMES[300] = "Café Terrace East"
d.clear()
d.call("ExecuteCommand", "LUA_ACTION", d.table({"ACTION": "UpdateNames"}))
renamed = [(dev, p["NAME"]) for dev, cmd, p, _ in d.device_cmds("DL_CONFIGURE") if p.get("RENAME") == "1"]
check(renamed == [(1003, "Café Terrace East")], f"Update Camera Names renames only what changed ({renamed})")
check(d.prop("Status") == "Camera names updated: 1 renamed", f"rename status ({d.prop('Status')})")
check(len(d.call("BuildCandidates")[0]) == 0, "nothing left to add")

# ---------------------------------------------------------------- live status from the cameras
d.clear()
for dev, name, ip in ((1001, "Pool", "192.168.50.80"), (1002, "Front", "192.168.50.80"), (1003, "Garden", "192.168.50.81"), (1004, "Gate", "192.168.50.82")):
    d.call("ExecuteCommand", "DL_CAMERA_STATUS", d.table({"DEVICE_ID": str(dev), "NAME": name, "ONLINE": "1", "ADDRESS": ip}))
d.call("ExecuteCommand", "DL_CAMERA_STATUS", d.table({"DEVICE_ID": "1005", "NAME": "Back Door", "ONLINE": "1", "ADDRESS": "192.168.50.83"}))
check(d.prop("Cameras") == "5 cameras - 5 online" and d.var("ALL_ONLINE") == "1", f"camera summary ({d.prop('Cameras')})")
check(d.prop("Status").startswith(("Added 5 cameras", "Camera names updated", "All cameras online")), f"status ({d.prop('Status')})")
d.clear()
d.call("ExecuteCommand", "DL_CAMERA_STATUS", d.table({"DEVICE_ID": "1004", "NAME": "Gate", "ONLINE": "0"}))
check("Camera Offline" in d.events() and d.var("LAST_OFFLINE_CAMERA") == "Gate", "Camera Offline event names the camera")
check([p.get("icon") for _, c, p in d.proxy("ICON_CHANGED")] == ["error"], "tile shows the error state")
check("offline: Gate" in d.prop("Cameras"), f"summary lists the offline camera ({d.prop('Cameras')})")
d.clear()
d.call("ExecuteCommand", "DL_CAMERA_STATUS", d.table({"DEVICE_ID": "1004", "NAME": "Gate", "ONLINE": "", "DISABLED": "1"}))
check(d.prop("Cameras") == "5 cameras - 4 online - 1 disabled" and d.var("ALL_ONLINE") == "1", f"disabled camera is not a problem ({d.prop('Cameras')})")
check([p.get("icon") for _, c, p in d.proxy("ICON_CHANGED")] == ["on"], "tile back to normal")
check(d.call("TestCondition", "ALL_ONLINE", d.table({"VALUE": "Online"})) is True, "conditional: all (enabled) cameras online")
d.call("ExecuteCommand", "DL_CAMERA_STATUS", d.table({"DEVICE_ID": "1004", "NAME": "Gate", "ONLINE": "1", "DISABLED": "0"}))
d.call("ExecuteCommand", "DL_CAMERA_STATUS", d.table({"DEVICE_ID": "1005", "NAME": "Back Door", "ONLINE": "1", "H264": "0"}))
check("no H.264 video (run Set All Sub Streams To H.264): Back Door" in d.prop("Cameras"), f"cameras without H.264 video listed ({d.prop('Cameras')})")
d.clear()
d.g.Properties["Sub Stream To H.264"] = "Off"
d.call("OnPropertyChanged", "Sub Stream To H.264")
check(not d.device_cmds("DL_FIX_SUBSTREAM"), "Off: cameras are left alone")
d.g.Properties["Sub Stream To H.264"] = "Automatic"
d.call("OnPropertyChanged", "Sub Stream To H.264")
check(sorted(dev for dev, cmd, p, _ in d.device_cmds("DL_FIX_SUBSTREAM")) == [1001, 1002, 1003, 1004, 1005], "choosing Automatic applies it to the cameras already added")
d.clear()
d.call("ExecuteCommand", "LUA_ACTION", d.table({"ACTION": "SubStreamsH264"}))
check(sorted(dev for dev, cmd, p, _ in d.device_cmds("DL_FIX_SUBSTREAM")) == [1001, 1002, 1003, 1004, 1005], "Set All Sub Streams To H.264 asks every camera")
d.call("ExecuteCommand", "DL_CAMERA_STATUS", d.table({"DEVICE_ID": "1005", "NAME": "Back Door", "ONLINE": "1", "H264": "1"}))
check("H.264" not in d.prop("Cameras"), "fixed camera drops off the list")
d.clear()
for _ in range(2):
    d.call("ExecuteCommand", "DL_CAMERA_STATUS", d.table({"DEVICE_ID": "1003", "ONLINE": "1", "NEED_LOGIN": "1"}))
sent = d.device_cmds("DL_CONFIGURE", 1003)
check(len(sent) == 1 and sent[0][2]["PASSWORD"] == PASS and sent[0][2]["ADDRESS"] == "192.168.50.81",
      "a camera that lost its login gets the hub's login again (once, not on every report)")

d.clear()
d.call("ExecuteCommand", "DL_CAMERA_ALERT", d.table({"DEVICE_ID": "1003", "NAME": "Garden", "TYPE": "Person", "TIME": "2026-10-03 22:00:00"}))
check(d.events() == ["Camera Alert"] and d.var("LAST_ALERT_CAMERA") == "Garden" and d.var("LAST_ALERT_TYPE") == "Person", "Camera Alert event with camera and type")
check([p.get("icon") for _, c, p in d.proxy("ICON_CHANGED")] == ["alert"], "tile shows the alert")
check(len(d.call("GetNotificationAttachmentBytes")) > 0, "notification snapshot fetched from the alerting camera")
check(d.call("GetNotificationAttachmentURL").startswith("http://admin:Secr3t%21pw@192.168.50.81/ISAPI/Streaming/channels/101/picture"), "live snapshot URL of the alerting camera")
check(d.call("TestCondition", "LAST_ALERT_TYPE", d.table({"VALUE": "Person", "LOGIC": "EQUAL"})) is True, "conditional Last alert = Person")
d.call("ExecuteCommand", "DL_CAMERA_STATUS", d.table({"DEVICE_ID": "1003", "ONLINE": "1",
                                                     "SNAPSHOT": "ISAPI/Streaming/channels/101/picture?videoResolutionWidth=1280&videoResolutionHeight=720"}))
check(d.call("GetNotificationAttachmentURL").endswith("/ISAPI/Streaming/channels/101/picture?videoResolutionWidth=1280&videoResolutionHeight=720"),
      "notification picture: the phone-sized picture the camera reports")

# ---------------------------------------------------------------- master alerts: tile tap
d.timers()
d.clear()
d.call("ReceivedFromProxy", 5001, "SELECT", d.table({}))
pushed = {dev: p["ENABLED"] for dev, cmd, p, _ in d.device_cmds("DL_HUB_ALERTS")}
check(pushed == {1001: "0", 1002: "0", 1003: "0", 1004: "0", 1005: "0"}, f"tile tap turns alerts off on every camera ({pushed})")
check("Alerts Off" in d.events() and [p.get("icon") for _, c, p in d.proxy("ICON_CHANGED")] == ["off"], "Alerts Off event and tile")
d.clear()
d.call("ExecuteCommand", "SNOOZE_ALERTS", d.table({"Minutes": "30"}))
check("snoozed until" in d.prop("Status"), f"snooze shown in status ({d.prop('Status')})")
d.call("ExecuteCommand", "SET_ALERTS", d.table({"State": "On"}))
check(d.var("ALERTS_ENABLED") == "1" and "Alerts On" in d.events(), "SET_ALERTS On resumes")

# ---------------------------------------------------------------- login change, hello and pruning
d.clear()
d.g.Properties["Password"] = "N3w!pass"
d.call("OnPropertyChanged", "Password")
d.timers()
sent = d.device_cmds("DL_CONFIGURE")
check(len(sent) == 5 and all(p["PASSWORD"] == "N3w!pass" for _, _, p, _ in sent), "new login pushed to all cameras")
d.g.Properties["Password"] = PASS          # back to the login the test devices accept
d.call("OnPropertyChanged", "Password")
d.timers(); d.timers(); d.timers()
d.clear()
d.run("C4I_DEVICES = { 1001, 1003 }; DELETED_DEVICES = { [1002] = true, [1004] = true, [1005] = true }")
d.call("OnDriverLateInit")
hello = sorted(dev for dev, cmd, p, _ in d.device_cmds("DL_HUB_HELLO"))
check(hello == [1001, 1003] and d.prop("Cameras").startswith("2 cameras"), "startup: hello to cameras in the project, deleted ones dropped")

# deleted cameras can be added again (Director's list is trusted even if a deleted device keeps its name)
d.run("C4I_DEVICES = { 1001 }; DELETED_DEVICES = {}")
discover(d)
again = [(x.address, x.channel) for x in d.call("BuildCandidates")[0].values()]
check(("192.168.50.81", 1) in again, f"deleted cameras are offered again ({again})")
check(d.prop("Cameras").startswith("1 camera"), f"pruned list ({d.prop('Cameras')})")

# Ignored Cameras: a camera IP, an NVR channel
d.g.Properties["Ignored Cameras"] = "192.168.50.81, 192.168.50.80/4"
d.call("OnPropertyChanged", "Ignored Cameras")
left = [(x.address, x.channel) for x in d.call("BuildCandidates")[0].values()]
check(("192.168.50.81", 1) not in left and ("192.168.50.80", 4) not in left and ("192.168.50.82", 1) in left, f"ignored cameras are not offered ({left})")
check("- 2 ignored" in d.prop("Found On Network"), f"Found On Network counts them ({d.prop('Found On Network')})")
d.g.Properties["Ignored Cameras"] = ""
d.call("OnPropertyChanged", "Ignored Cameras")

# a camera running an older camera driver is reported
d.clear()
d.call("ExecuteCommand", "DL_CAMERA_STATUS", d.table({"DEVICE_ID": "1001", "NAME": "Pool", "ONLINE": "1", "VERSION": "0.8.0"}))
check("runs camera driver 0.8.0" in d.prop("Status"), f"version mismatch explained ({d.prop('Status')})")
d.call("ExecuteCommand", "DL_CAMERA_STATUS", d.table({"DEVICE_ID": "1001", "NAME": "Pool", "ONLINE": "1", "VERSION": "test"}))
check("camera driver" not in d.prop("Status"), f"the notice clears once the camera runs the same version ({d.prop('Status')})")

# ---------------------------------------------------------------- a login that does not work never adds cameras
d = hub()
d.g.Properties["Password"] = "wrong"
discover(d)
d.clear()
d.call("ExecuteCommand", "LUA_ACTION", d.table({"ACTION": "AddCameras"}))
check(len(list(d.g.ADDED.values())) == 0, "wrong password: no camera is added")
check(d.prop("Status").startswith("Login failed on 192.168.50.80"), f"status names the device that refused the login ({d.prop('Status')})")

# ---------------------------------------------------------------- NVR channels whose camera is disconnected are not offered
NVR_STATUS["xml"] = (f"<InputProxyChannelStatusList {NS}><InputProxyChannelStatus><id>3</id><online>true</online></InputProxyChannelStatus>"
                     "<InputProxyChannelStatus><id>4</id><online>false</online></InputProxyChannelStatus></InputProxyChannelStatusList>")
d = hub()
discover(d)
c = [(x.address, x.channel) for x in d.call("BuildCandidates")[0].values()]
check(("192.168.50.80", 4) not in c and ("192.168.50.80", 3) in c, f"dead NVR channel skipped, live one offered ({c})")
check("- 1 offline on the NVR" in d.prop("Found On Network"), f"Found On Network says so ({d.prop('Found On Network')})")
NVR_STATUS["xml"] = None

# ---------------------------------------------------------------- an NVR that refuses the login while it starts (after a firmware upgrade)
NVR_START = {"starting": False}


def nvr_starting(method, url, headers, body):
    if NVR_START["starting"] and url.startswith("http://192.168.50.80:90/"):
        return 401, {"WWW-Authenticate": 'Digest realm="NVR", qop="auth", nonce="abc123", stale="FALSE"'}, ""
    return network(method, url, headers, body)


def tick(d):
    d.run("for _, t in ipairs(TIMERS) do if t.active and t.rep then t.fn(t) end end")


def feed(d):
    for m in (probe_match("192.168.50.80", "DS-7616NXI-K2(D)", port=90, digital=16), probe_match("192.168.50.81", "DS-2CD2087G2-L")):
        d.call("HandleSadpData", m)
    d.timers()


def nvr_tries(d):
    return [e for e in d.g.HTTP_LOG.values() if e["url"].startswith("http://192.168.50.80:90/") and e["auth"]]


d = hub(nvr_starting)
d.timers(); d.timers()
NVR_START["starting"] = True
d.call("StartDiscovery", "test"); feed(d)
check(d.prop("Status").startswith("Login failed on 192.168.50.80"), f"NVR still starting: login refused ({d.prop('Status')})")
NVR_START["starting"] = False
d.clear()
d.call("ExecuteCommand", "SEARCH_NETWORK", d.table({})); feed(d)
check(not nvr_tries(d) and d.prop("Status").startswith("Login failed"), "a search from programming does not retry the refused login")
d.clear()
d.call("ExecuteCommand", "LUA_ACTION", d.table({"ACTION": "Search"})); feed(d)
check(len(nvr_tries(d)) >= 1 and not d.prop("Status").startswith("Login failed"),
      f"Search Network run by hand tries the login once more ({d.prop('Status')})")

NVR_START["starting"] = True
d.call("StartDiscovery", "test"); feed(d)
NVR_START["starting"] = False
d.call("OnPropertyChanged", "Password")    # the same password entered again
d.timers(); feed(d)
check(not d.prop("Status").startswith("Login failed"), f"the same password entered again is tried again ({d.prop('Status')})")

NVR_START["starting"] = True
d.call("StartDiscovery", "test"); feed(d)
NVR_START["starting"] = False
d.clear()
tick(d)
check(not nvr_tries(d) and d.prop("Status").startswith("Login failed"), "within 15 minutes nothing is retried")
d.run("AUTH_RETRY_S = 0")
tick(d)
check(len(nvr_tries(d)) >= 1 and not d.prop("Status").startswith("Login failed") and not d.g.gLoginFailed["192.168.50.80"],
      f"after 15 minutes the hub tries the NVR once more by itself ({d.prop('Status')})")
d.run("AUTH_RETRY_S = 900")

# ---------------------------------------------------------------- update check: off unless turned on
GITHUB["calls"] = 0
d = hub()
d.timers()
check(GITHUB["calls"] == 0 and "update" not in d.prop("Driver Version"), "Check For Updates is off by default: GitHub is never contacted")
d.g.Properties["Check For Updates"] = "On"
d.call("OnPropertyChanged", "Check For Updates")
gh = [e for e in d.g.HTTP_LOG.values() if e["url"].startswith("https://api.github.com/")]
check(GITHUB["calls"] == 1 and gh and gh[0]["ua"] == "DirectorLink-Hikvision/test", "turned on: one request, with the hub User-Agent")
check("update available: 9.9.9" in d.prop("Driver Version"), f"Driver Version shows the newer release ({d.prop('Driver Version')})")
d.g.Properties["Check For Updates"] = "Off"
d.call("OnPropertyChanged", "Check For Updates")
check("update" not in d.prop("Driver Version") and GITHUB["calls"] == 1, "turned off again: no request, no notice")
check("/repos/DirectorLink/DirectorLink-Hikvision/" in [e["url"] for e in d.g.HTTP_LOG.values() if "github" in e["url"]][0],
      "asks the repository at its current address (DirectorLink organisation)")
GITHUB["calls"], GITHUB["moved"] = 0, True
d.g.Properties["Check For Updates"] = "On"
d.call("OnPropertyChanged", "Check For Updates")
check(GITHUB["calls"] == 2 and GITHUB["last"].endswith("/repositories/1403883922/releases/latest") and "update available: 9.9.9" in d.prop("Driver Version"),
      "if the repository moves again, the check follows GitHub's redirect once")
GITHUB["moved"] = False

# ---------------------------------------------------------------- failures are explained
d = hub()
discover(d)
d.call("ExecuteCommand", "LUA_ACTION", d.table({"ACTION": "AddCameras"}))
list(d.g.ADDED.values())[-1].cb(0, d.table({}))
check("Upload DirectorLink-Hikvision-Camera.c4z" in d.prop("Status"), f"missing camera driver explained ({d.prop('Status')})")

d = Driver("hub")
d.g.Properties["Username"] = ""
d.call("OnDriverInit")
d.call("OnDriverLateInit")
check(d.prop("Status").startswith("Setup: enter the camera Username and Password"), f"setup guidance without a login ({d.prop('Status')})")

d = Driver("hub")
d.g.Properties["Username"] = USER
d.call("OnDriverInit")
d.call("OnDriverLateInit")
check(not any(t.ms == 5000 for t in d.g.TIMERS.values()), "no startup search until the password is entered")

finish()
