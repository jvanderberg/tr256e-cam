# tr256e-cam

A macOS camera extension that makes the **Mileseey TR256E** thermal camera work as a
normal webcam. Once installed, a camera called **TR256E Thermal** shows up in
QuickTime, Photo Booth, FaceTime, Zoom, browsers and anything else that uses
AVFoundation.

Plugged in over USB-C, the camera presents itself as a webcam ("UVC Camera 0").
On macOS, QuickTime shows about two seconds of video, freezes, and reports
"Cannot record". After that the webcam function stays dead until the camera is
unplugged and plugged back in. It fails the same way on Windows.

## What's wrong

Short version: **the camera always sends H.264, whatever video format the
computer asks for.** The details below come from reading the camera's USB
descriptors and streaming from it directly with libusb.

### What the camera presents over USB

| Field | Value |
| --- | --- |
| Vendor / product ID | `1d6b:1110` (`1d6b` is the Linux Foundation ID used by Linux USB gadget drivers) |
| Manufacturer / product strings | `CVIOT` / `IR256` |
| Interface 0 | UVC VideoControl, `bcdUVC` 1.00, plus a UVC H.264 extension unit (GUID `A29E7641-DE04-47E3-8B2B-F4341AFF003B`) |
| Interface 1 | UVC VideoStreaming on a **bulk** endpoint (`0x81`, 512-byte packets) |
| Interface 2 | USB mass storage (the photo/video storage) |

The VideoStreaming interface advertises five formats, all at 256x342 and 25 fps:

| Index | Format |
| --- | --- |
| 1 | HEVC (frame-based) |
| 2 | H.264 (frame-based) |
| 3 | MJPEG |
| 4 | NV12 (uncompressed) |
| 5 | YUY2 (uncompressed) |

The picture is a copy of the camera's screen, overlay included: the 256x192
thermal image plus the temperature readouts, color bar and battery icon.

### What it actually sends

A host picks a format by sending a UVC probe/commit request with the format's
index, then reads the stream. When asked for **MJPEG (index 3)**, the camera
streamed H.264 anyway: an Annex-B elementary stream, High profile, 256x342, with
SPS/PPS and an IDR frame every 2 seconds. That's what you'd get from index 2.
The raw dump decodes cleanly with ffmpeg once the stream is labeled as H.264.

### Why the computer gives up

AVFoundation's capture modes for this device are uncompressed pixel formats
(`uyvy422`, `yuyv422`, `nv12`, ...). When macOS negotiates one of those, the
data that arrives doesn't match the format or frame size it asked for. Through
AVFoundation, the stream delivered 13 frames and then nothing. QuickTime holds
on for about two seconds before giving up. The streaming interface is then left
mid-stream, and nothing recovers it short of re-plugging the camera.

Reading the same endpoint directly with libusb, requesting H.264 and treating
the payload as H.264, streams indefinitely at a steady 25 fps. So the camera and
cable are fine. The failure is the mismatch between what the camera advertises
and what it sends.

Two other oddities:

- **The descriptors are internally inconsistent.** The VideoControl header
  says UVC 1.00, but frame-based formats (HEVC/H.264 here) were only added in
  UVC 1.1.
- **Video goes over a bulk endpoint.** Almost every webcam uses isochronous
  transfers. UVC allows bulk, but host drivers get far less testing on it.

Since the problem is in the camera's firmware, every operating system's
built-in webcam driver runs into it, which is why it also fails on Windows.

## How this works around it

```
camera --USB--> tr256e-helper --H.264 over 127.0.0.1--> camera extension --> any app
               (root daemon, libusb)                     (VideoToolbox decode)
```

| Piece | What it does |
| --- | --- |
| `Helper/` (`tr256e-helper`) | A root launchd daemon registered with `SMAppService`. It listens on `127.0.0.1:47256`. While a client is connected, it claims the camera with libusb, commits the H.264 format, reassembles frames from the UVC payload headers (FID/EOF bits) and forwards each one as `[u32 big-endian length][Annex-B access unit]`. |
| `CameraExtension/` | A CoreMediaIO camera extension. When an app opens TR256E Thermal, it connects to the helper, decodes with VideoToolbox, and serves NV12 at 768x1026 (3x nearest-neighbor, so the pixels stay sharp) or the native 256x342. While no video is arriving, it shows a dark placeholder frame. |
| `App/` | A small window that installs the extension and enables the helper. |
| `tools/uvcgrab.py` | A standalone Python recorder that does what the helper does, for people who'd rather not install anything. |

Why the helper has to run as root: macOS's built-in webcam driver
(UVCAssistant) claims the camera's video interface as soon as it's plugged in,
and only root can take it away. Camera extensions are sandboxed and can't do
that, which is why the USB work lives in a separate daemon.

### Side effects

- **The storage drive disappears while the camera is in use.** On macOS,
  libusb's "detach kernel driver" captures the entire USB device, not just one
  interface, so the drive unmounts until you stop using TR256E Thermal. For this
  reason the helper only claims the camera while something is streaming.
- **"UVC Camera 0" still shows up in camera menus.** That's macOS's driver for
  the camera's broken built-in webcam function, and it will never work. Pick
  **TR256E Thermal** instead. Apps remember the choice.
- **QuickTime may say "The operation could not be completed"** as soon as you
  open a new movie recording. QuickTime opens the last camera you used. If that
  was UVC Camera 0, start with the thermal camera unplugged and choose TR256E
  Thermal from the menu next to the record button. Or set it directly:
  ```sh
  defaults write com.apple.QuickTimePlayerX \
    MGDeviceRecordingDocumentViewControllerVideoDeviceSelectionUniqueID \
    -string F6BD0896-F004-4AE6-A37F-6F520AC1EA17
  ```
- **Photo Booth mirrors the picture.** It mirrors every camera. Recordings
  made by other apps aren't mirrored.

## Requirements

- macOS 15 or later, on Apple Silicon (the helper links Homebrew's arm64 libusb)
- Xcode 16
- A paid Apple Developer account. Camera extensions are system extensions,
  which need the `com.apple.developer.system-extension.install` entitlement.
- `brew install xcodegen libusb`

## Build and install

The project is generated with XcodeGen from `project.yml`. It's set up for the
original author's team and bundle IDs, which can't be reused on another
account. Change these to your own first:

| File | What to change |
| --- | --- |
| `project.yml` | `DEVELOPMENT_TEAM`, `bundleIdPrefix`, the three `PRODUCT_BUNDLE_IDENTIFIER`s, the extension's `PRODUCT_NAME`, and the helper plist path |
| `App/TR256ECamApp.swift` | `kExtensionID`, `kHelperPlist` |
| `App/App.entitlements`, `CameraExtension/CameraExtension.entitlements` | the app group |
| `Helper/com.quirklocal.tr256ecam.helper.plist` | rename the file, and update `Label` and `AssociatedBundleIdentifiers` |

Then:

```sh
xcodegen generate
xcodebuild -scheme TR256ECam -configuration Debug -derivedDataPath build \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
cp -R "build/Build/Products/Debug/TR256E Camera.app" /Applications/
open "/Applications/TR256E Camera.app"
```

`-allowProvisioningUpdates` lets Xcode register the app IDs and create
development profiles. Your account must be signed in under Xcode > Settings >
Accounts.

In the app, click **Install / Update** and **Enable**. Then, in System Settings >
General > Login Items & Extensions, allow the camera extension and allow
"TR256E Camera" to run in the background. System extensions only activate when
the app runs from `/Applications`.

After rebuilding, copy the app to `/Applications` again and click both buttons
again. **Enable** re-registers the helper so launchd picks up the new binary.

## Recording without the extension

`tools/uvcgrab.py` reads the camera directly and writes H.264 to stdout:

```sh
pip install pyusb
sudo python3 tools/uvcgrab.py 30 | ffmpeg -f h264 -framerate 25 -i - -c copy thermal.mp4
```

Leave out the seconds argument to record until Ctrl-C. Don't run it while the
helper is streaming, since only one of them can hold the camera.

## Debugging

```sh
tail -f /var/log/tr256e-helper.log      # helper: claims, streams, frame counts
/usr/bin/log stream --predicate 'process == "com.quirklocal.tr256ecam.camera"'
systemextensionsctl list
ffmpeg -f avfoundation -list_devices true -i ""
```

In zsh, `log` is a shell builtin, so use `/usr/bin/log`.

## Bonus: the photos contain temperature data

Each `*-IR.jpg` in the camera's `DCIM` folder is a normal 256x342 JPEG of the
screen with roughly 173 KB of data appended after the JPEG end marker. In the
files examined:

| Offset after `FF D9` | Contents |
| --- | --- |
| 0 | 2 bytes, `00 01` |
| 2 | `uint16` LE width (180) |
| 4 | `uint16` LE height (240) |
| 6 | 14-byte ASCII timestamp, `YYYYMMDDhhmmss` |
| 20 | width x height `float32` LE temperatures in °C |
| after that | about 532 bytes containing `Raythink`, the model name `TR256E`, and a JSON block of capture settings (emissivity, palette, ...) |

Every photo can therefore be analyzed after the fact, at 180x240, without the
vendor's software. This layout comes from inspecting the files; it isn't
documented anywhere.

## License

MIT. See [LICENSE](LICENSE).

Not affiliated with Mileseey.
