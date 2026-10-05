"""In-process test harness: runs a driver's assembled Lua in a real Lua 5.1 runtime
(lupa) against a stubbed Control4 API. No network access.

HTTP (C4:url) is answered by a Python `responder(method, url, headers, body)` that
returns (code, headers, body) - so request flows can be tested deterministically.
"""
import base64
import hashlib
import os
import re
import sys

import lupa.lua51 as lupa

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import build  # noqa: E402  (assemble_lua)

STUB = r"""
EVENTS = {}; VARS = {}; PROXY = {}; DEVICE_CMDS = {}; TIMERS = {}; PERSIST = {}; RENAMED = {}
HISTORY = {}; ADDED = {}; NET = {}; ATTRIBS = {}; HTTP_LOG = {}
PROXY_PROPS = ""; BINDING_ADDRESS = ""; DEVICE_ID = 900; PROXY_DEVICE = 901; C4I_DEVICES = {}
local timerSeq = 0
C4 = {}
VAR_ORDER = {}; SEQ = {}
-- Like Director: adding a variable that already exists keeps its value (driver updates)
function C4:AddVariable(n, v) if VARS[n] == nil then VARS[n] = v end; VAR_ORDER[#VAR_ORDER + 1] = n; return 1, true end
function C4:SetVariable(n, v) VARS[n] = v; SEQ[#SEQ + 1] = "var:" .. n end
function C4:FireEvent(n) EVENTS[#EVENTS + 1] = n; SEQ[#SEQ + 1] = "event:" .. n end
function C4:UpdateProperty(n, v) Properties[n] = v end
function C4:SetPropertyAttribs(n, v) ATTRIBS[n] = v end
function C4:SendToProxy(b, c, p, k) PROXY[#PROXY + 1] = { b, c, p } end
function C4:SendToDevice(id, c, p, allowEmpty, log) DEVICE_CMDS[#DEVICE_CMDS + 1] = { id, c, p, log } end
function C4:GetProxyDevices() return PROXY_DEVICE end
function C4:GetDeviceID() return DEVICE_ID end
DELETED_DEVICES = {}
DISPLAY_NAMES = {}
function C4:GetDeviceDisplayName(id) if DELETED_DEVICES[id] then return nil end return DISPLAY_NAMES[id] or ("Hub " .. tostring(id)) end
UI_PROPS = {}
function C4:SendUIRequest(id) return UI_PROPS[id] or PROXY_PROPS end
function C4:GetBindingAddress() return BINDING_ADDRESS end
function C4:RenameDevice(id, name) RENAMED[#RENAMED + 1] = { id, name } end
function C4:RecordHistory(...) HISTORY[#HISTORY + 1] = { ... } end
function C4:RoomGetId() return 81 end
C4I_BY_NAME = {}
function C4:GetDevicesByC4iName(n) return C4I_BY_NAME[n] or C4I_DEVICES end
function C4:AddDevice(file, room, name, cb) ADDED[#ADDED + 1] = { file = file, room = room, name = name, cb = cb } end
function C4:CreateNetworkConnection(...) NET[#NET + 1] = { "create", ... } end
function C4:NetPortOptions(...) NET[#NET + 1] = { "options", ... } end
function C4:NetConnect(...) NET[#NET + 1] = { "connect", ... } end
function C4:NetDisconnect(...) NET[#NET + 1] = { "disconnect", ... } end
function C4:SendToNetwork(b, p, data) NET[#NET + 1] = { "send", b, p, data } end
function C4:PersistSetValue(n, v) PERSIST[n] = v end
function C4:PersistGetValue(n) return PERSIST[n] end
function C4:PersistDeleteValue(n) PERSIST[n] = nil; DELETED = n end
function C4:GetDriverConfigInfo() return "900" end
function C4:DebugLog(s) end
function C4:ErrorLog(s) end
function C4:Hash(alg, s) return PY_MD5(s) end
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
function C4:Base64Encode(s)  -- pure Lua: binary data (JPEG) must not cross into Python as text
  local out = {}
  for i = 1, #s, 3 do
    local a, b, c = string.byte(s, i, i + 2)
    local n = a * 65536 + (b or 0) * 256 + (c or 0)
    local c1, c2 = math.floor(n / 262144) % 64, math.floor(n / 4096) % 64
    local c3, c4 = math.floor(n / 64) % 64, n % 64
    out[#out + 1] = B64:sub(c1 + 1, c1 + 1) .. B64:sub(c2 + 1, c2 + 1)
      .. (b and B64:sub(c3 + 1, c3 + 1) or "=") .. (c and B64:sub(c4 + 1, c4 + 1) or "=")
  end
  return table.concat(out)
end
function C4:Base64Decode(s) return PY_B64D(s) end
function C4:SetTimer(ms, fn, rep)
  timerSeq = timerSeq + 1
  local t = { id = timerSeq, ms = ms, fn = fn, rep = rep, active = true }
  function t:Cancel() self.active = false end
  TIMERS[#TIMERS + 1] = t
  return t
end
-- Run every pending one-shot timer (repeating ones stay)
function RunOneShotTimers()
  local list = TIMERS; TIMERS = {}
  for _, t in ipairs(list) do
    if t.active and not t.rep then t.active = false; t.fn(t) elseif t.active then TIMERS[#TIMERS + 1] = t end
  end
end
-- C4:url(): answered synchronously by PY_HTTP
function C4:url()
  local x = { opts = {} }
  function x:SetOptions(o) self.opts = o; return self end
  function x:OnDone(f) self.done = f; return self end
  local function run(self, method, url, body, headers)
    HTTP_LOG[#HTTP_LOG + 1] = { method = method, url = url, auth = headers and headers["Authorization"], ua = headers and headers["User-Agent"] }
    local code, hdrs, rbody = PY_HTTP(method, url, headers, body)
    if code == nil then self.done(self, {}, 7, "Couldn't connect to server") return self end
    self.done(self, { { code = code, headers = hdrs, body = rbody } }, 0, nil)
    return self
  end
  function x:Get(url, headers) return run(self, "GET", url, nil, headers) end
  function x:Put(url, body, headers) return run(self, "PUT", url, body, headers) end
  function x:Post(url, body, headers) return run(self, "POST", url, body, headers) end
  function x:Custom(url, m, body, headers) return run(self, m, url, body, headers) end
  return x
end
-- TCP client: connects never complete in tests (event stream is tested through its parser)
function C4:CreateTCPClient()
  local c = {}
  for _, m in ipairs({ "OnConnect", "OnRead", "OnDisconnect", "OnError", "OnResolve" }) do c[m] = function(self) return self end end
  function c:Connect() return self end
  function c:Close() end
  return c
end
print = function() end
"""


def defaults_from_xml(path):
    xml = open(path, encoding="utf-8").read()
    props = {}
    for block in re.findall(r"<property>(.*?)</property>", xml, re.S):
        name = re.search(r"<name>(.*?)</name>", block).group(1)
        d = re.search(r"<default>(.*?)</default>", block, re.S)
        props[name] = d.group(1) if d else ""
    return props


class Driver:
    def __init__(self, driver, responder=None):
        self.lua = lupa.LuaRuntime(unpack_returned_tuples=True)
        g = self.lua.globals()
        self.responder = responder or (lambda m, u, h, b: (None, None, None))
        g.PY_MD5 = lambda s: hashlib.md5(s.encode("latin-1")).hexdigest().upper()
        g.PY_B64E = lambda s: base64.b64encode(s.encode("latin-1")).decode()
        g.PY_B64D = lambda s: base64.b64decode(s).decode("latin-1")
        g.PY_HTTP = self._http
        g.Properties = self.lua.table_from(defaults_from_xml(os.path.join(ROOT, "src", driver, "driver.xml")))
        self.lua.execute(STUB)
        self.lua.execute(build.assemble_lua(driver, "test"))
        self.g = g

    def _http(self, method, url, headers, body):
        h = dict(headers) if headers is not None else {}
        code, rh, rb = self.responder(method, url, h, body)
        if code is None:
            return None, None, None
        return code, self.lua.table_from(rh or {}), rb

    # helpers
    def call(self, fn, *args):
        return self.g[fn](*args)

    def table(self, d):
        return self.lua.table_from(d)

    def run(self, code):
        self.lua.execute(code)

    def events(self):
        return list(self.g.EVENTS.values())

    def clear(self):
        self.lua.execute("EVENTS = {}; PROXY = {}; DEVICE_CMDS = {}; HTTP_LOG = {}; RENAMED = {}; HISTORY = {}")

    def var(self, name):
        return self.g.VARS[name]

    def prop(self, name):
        return self.g.Properties[name]

    def proxy(self, cmd=None, binding=None):
        out = []
        for m in self.g.PROXY.values():
            if (cmd is None or m[2] == cmd) and (binding is None or m[1] == binding):
                out.append((m[1], m[2], dict(m[3]) if m[3] is not None else {}))
        return out

    def device_cmds(self, cmd=None, device=None):
        out = []
        for m in self.g.DEVICE_CMDS.values():
            if (cmd is None or m[2] == cmd) and (device is None or m[1] == device):
                out.append((m[1], m[2], dict(m[3]) if m[3] is not None else {}, m[4]))
        return out

    def timers(self):
        self.lua.execute("RunOneShotTimers()")


FAILS = []


def check(cond, label):
    print(("PASS " if cond else "FAIL ") + label)
    if not cond:
        FAILS.append(label)


def finish():
    print()
    if FAILS:
        print(f"{len(FAILS)} FAILED")
        sys.exit(1)
    print("ALL PASSED")
