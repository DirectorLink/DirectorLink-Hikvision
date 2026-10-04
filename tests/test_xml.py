"""driver.xml checks (offline).   python tests/test_xml.py

Catches definitions Composer rejects at install time - for example a property of
type PASSWORD, which Composer reports as "Property Invalid ... Object reference not
set to an instance of an object". Password fields are STRING + <password>true</password>.
"""
import os
import xml.etree.ElementTree as ET

from harness import ROOT, check, finish

PROPERTY_TYPES = {"STRING", "LIST", "RANGED_INTEGER", "RANGED_FLOAT", "LABEL", "DYNAMIC_LIST",
                  "DEVICE_SELECTOR", "COLOR_SELECTOR", "LINK", "SCROLL", "TRACK"}
PARAM_TYPES = {"STRING", "LIST", "RANGED_INTEGER", "RANGED_FLOAT", "DEVICE_SELECTOR", "COLOR_SELECTOR", "CUSTOM_SELECT", "DYNAMIC_LIST"}
CONDITIONAL_TYPES = {"SIMPLE", "BOOL", "NUMBER", "STRING", "LIST", "ROOM", "DEVICE"}

for drv in ("hub", "camera"):
    root = ET.parse(os.path.join(ROOT, "src", drv, "driver.xml")).getroot()
    props = root.findall("config/properties/property")
    names = [p.findtext("name") for p in props]
    bad = [(p.findtext("name"), p.findtext("type")) for p in props if (p.findtext("type") or "").strip() not in PROPERTY_TYPES]
    check(not bad, f"{drv}: every property type is one Composer supports {bad or ''}")
    check(len(names) == len(set(names)), f"{drv}: property names are unique")
    lists = [p.findtext("name") for p in props if p.findtext("type") == "LIST" and p.findtext("default") not in [i.text for i in p.findall("items/item")]]
    check(not lists, f"{drv}: every LIST default is one of its items {lists or ''}")
    ranged = [p.findtext("name") for p in props if p.findtext("type") == "RANGED_INTEGER"
              and not (int(p.findtext("minimum")) <= int(p.findtext("default")) <= int(p.findtext("maximum")))]
    check(not ranged, f"{drv}: every RANGED_INTEGER default is in range {ranged or ''}")
    params = [(c.findtext("name"), q.findtext("type")) for c in root.findall("config/commands/command") for q in c.findall("params/param")
              if q.findtext("type") not in PARAM_TYPES]
    check(not params, f"{drv}: every command parameter type is valid {params or ''}")
    conds = [(c.findtext("name"), c.findtext("type")) for c in root.findall("conditionals/conditional") if c.findtext("type") not in CONDITIONAL_TYPES]
    check(not conds, f"{drv}: every conditional type is valid {conds or ''}")
    ids = [e.findtext("id") for e in root.findall("events/event")]
    check(len(ids) == len(set(ids)), f"{drv}: event ids are unique")
    pw = [p.findtext("name") for p in props if "password" in (p.findtext("name") or "").lower()]
    check(all(next(x for x in props if x.findtext("name") == n).findtext("password") == "true" for n in pw), f"{drv}: password fields are masked ({pw})")

    # DirectorLink brand: Composer name and maker metadata; no brand on anything the family sees
    expected = {"hub": "DirectorLink · Hikvision", "camera": "DirectorLink · Hikvision Camera"}[drv]
    check(root.findtext("name") == expected, f"{drv}: Composer name is '{expected}' ({root.findtext('name')})")
    check(root.findtext("creator") == "DirectorLink" and root.findtext("manufacturer") == "Hikvision"
          and root.findtext("copyright") == "Copyright 2026 DirectorLink", f"{drv}: creator, manufacturer and copyright")
    doc = root.find("config/documentation").get("file")
    check(doc == "www/documentation.html" and os.path.exists(os.path.join(ROOT, "src", drv, doc)), f"{drv}: documentation tab file exists ({doc})")
    family = ([p.get("name") for p in root.findall("proxies/proxy")] + [e.findtext("name") for e in root.findall("events/event")]
              + [c.findtext("connectionname") for c in root.findall("connections/connection")]
              + [c.findtext("name") for c in root.findall("conditionals/conditional")])
    check(not [n for n in family if "directorlink" in (n or "").lower()], f"{drv}: no brand in proxy, event, connection or conditional names")
    if drv == "camera":
        dup = {"IP Address", "Address", "HTTP Port", "HTTPS Port", "RTSP Port", "Use HTTPS", "Username", "Password"} & set(names)
        check(not dup, f"camera: no copy of the Control4 camera page's settings in Advanced Properties {sorted(dup) or ''}")

finish()
