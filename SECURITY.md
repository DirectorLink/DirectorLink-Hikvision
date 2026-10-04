# Security policy

## Reporting a vulnerability

Please report security problems privately, not in public issues.

Open this repository's **Security** tab and choose **Report a vulnerability**. This uses GitHub's private vulnerability reporting, so only the maintainers see your report.

Include what you found, the driver versions (**Driver Version** in Composer), and the steps to reproduce it. Leave out real passwords, addresses and names.

We will confirm the report, fix the problem in a new release, and credit you if you wish.

## Supported versions

Only the [latest release](../../releases/latest) gets security fixes.

## Scope

The drivers run on the Control4 controller and talk only to Hikvision cameras and NVRs on the home network, plus GitHub's release API once a day if **Check For Updates** is turned on. They store the camera login in the Control4 project and never log it.
