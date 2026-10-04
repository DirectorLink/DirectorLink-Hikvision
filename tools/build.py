"""Build the driver packages.

    python tools/build.py   ->  dist/DirectorLink-Hikvision.c4z          (the hub)
                                dist/DirectorLink-Hikvision-Camera.c4z
                                dist/SHA256SUMS.txt

Each driver.lua is assembled from the shared engine (src/common/*.lua) followed by
the driver's own src/<driver>/driver.lua. The version comes from the VERSION file
(e.g. 1.0.0): the packaged driver.xml gets <version> = major*10000 + minor*100
+ patch and today's <modified> date, and driver.lua gets DRIVER_SEMVER.
The files in src/ are not modified. Never rename a package: Composer updates by file name.
"""
import datetime
import hashlib
import os
import re
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src")
DIST = os.path.join(ROOT, "dist")
COMMON = ["core.lua", "isapi.lua"]
DRIVERS = {
    "hub": "DirectorLink-Hikvision.c4z",
    "camera": "DirectorLink-Hikvision-Camera.c4z",
}


def read_version():
    semver = open(os.path.join(ROOT, "VERSION"), encoding="utf-8").read().strip()
    m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(-[0-9A-Za-z.]+)?", semver)
    if not m:
        sys.exit(f"VERSION '{semver}' is not semver (MAJOR.MINOR.PATCH[-pre])")
    major, minor, patch = (int(x) for x in m.groups()[:3])
    if minor > 99 or patch > 99:
        sys.exit("minor and patch must be 0-99 for the integer driver version")
    return semver, major * 10000 + minor * 100 + patch


def assemble_lua(driver, semver):
    parts = []
    for name in COMMON:
        parts.append(f"-- ===== common/{name} =====\n" + open(os.path.join(SRC, "common", name), encoding="utf-8").read())
    parts.append(f"-- ===== {driver}/driver.lua =====\n" + open(os.path.join(SRC, driver, "driver.lua"), encoding="utf-8").read())
    lua = "\n".join(parts)
    lua, n = re.subn(r'^DRIVER_SEMVER = "[^"]*"', f'DRIVER_SEMVER = "{semver}"', lua, count=1, flags=re.M)
    if n != 1:
        sys.exit("DRIVER_SEMVER line not found")
    return lua


def stamp_xml(xml, number):
    now = datetime.datetime.now().strftime("%m/%d/%Y %H:%M")
    xml, n1 = re.subn(r"<version>\d+</version>", f"<version>{number}</version>", xml, count=1)
    xml, n2 = re.subn(r"<modified>[^<]*</modified>", f"<modified>{now}</modified>", xml, count=1)
    if n1 != 1 or n2 != 1:
        sys.exit("driver.xml: <version> or <modified> not found")
    return xml


def build(driver, package, semver, number):
    os.makedirs(DIST, exist_ok=True)
    out = os.path.join(DIST, package)
    if os.path.exists(out):
        os.remove(out)
    base = os.path.join(SRC, driver)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("driver.xml", stamp_xml(open(os.path.join(base, "driver.xml"), encoding="utf-8").read(), number))
        z.writestr("driver.lua", assemble_lua(driver, semver))
        for root, _, files in os.walk(os.path.join(base, "www")):
            for f in sorted(files):
                full = os.path.join(root, f)
                z.write(full, os.path.relpath(full, base).replace(os.sep, "/"))
        z.write(os.path.join(ROOT, "LICENSE"), "www/LICENSE.txt")
        z.write(os.path.join(ROOT, "NOTICE"), "www/NOTICE.txt")
    print(f"built {out}  ({os.path.getsize(out)} bytes)")


def main():
    semver, number = read_version()
    print(f"version {semver} (driver.xml version {number})")
    for driver, package in DRIVERS.items():
        build(driver, package, semver, number)
    with open(os.path.join(DIST, "SHA256SUMS.txt"), "w", newline="\n") as sums:
        for package in DRIVERS.values():
            digest = hashlib.sha256(open(os.path.join(DIST, package), "rb").read()).hexdigest()
            sums.write(f"{digest}  {package}\n")
    print("wrote dist/SHA256SUMS.txt")


if __name__ == "__main__":
    main()
