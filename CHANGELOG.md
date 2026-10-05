# Changelog

All notable changes to DirectorLink · Hikvision. Each release has fuller notes in [docs/releases](docs/releases).

## 1.1.0 — 2026-10-05

### Camera

- **DirectorLink camera agreement v1.** The camera driver sets the variables `DIRECTORLINK_CAMERA` = `1` and `DIRECTORLINK_CAMERA_KIND` = `camera` on every start, also after a driver update. They come after the existing variables, so existing programming is not affected. From DirectorLink 1.10 the app recognizes the cameras this way; DirectorLink 1.8 and 1.9 still recognize them by file name.
- **`LAST_ALERT` only carries the agreement's labels:** Person, Vehicle, Face, Motion, Line Crossing, Intrusion, Region Entrance, Region Exiting, Tamper, Scene Change, Object Left, Object Removed, Alarm Input, PIR, Animal, Package, License Plate. The *Alert* event, `LAST_ALERT` (set just before *Alert* fires) and the rules for when *Alert* fires (Alert On, the hub's switch, snooze, hold time) are unchanged.
- **More Hikvision detections go to the nearest one:** loitering → Intrusion, people gathering → Person, fast moving → Motion, parking and vehicle detection → Vehicle, license plate recognition → Vehicle with the alert label License Plate, defocus → Tamper. Animal, package and license plate targets give those alert labels.
- The **Last alert is** condition also offers Animal, Package and License Plate.

### Hub

- No changes apart from the version number.

## 1.0.6 — 2026-10-04

- Hub: **Check For Updates** asks the project's new address (DirectorLink organisation on GitHub) and follows GitHub's redirect if the project moves again.

## 1.0.5 — 2026-10-04

- Snapshots at the size each screen asks for, on cameras that can scale pictures.
- Lighter notification pictures: 1280 px when the camera can scale them, else the sub stream picture.
- Add New Cameras skips NVR channels whose camera is disconnected.
- The automatic switch to H.264 waits for an offline NVR channel instead of logging an error.
- The hub's "older camera driver" notice clears by itself.
- Test Snapshot and Setup Report show the real picture sizes.
- Optional **Check For Updates** on the hub (off by default).

## 1.0.2 — 2026-10-04

- First release.

Versions not listed were test builds and were not published.
