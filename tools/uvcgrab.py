"""Stream H.264 from the Mileseey TR256E's bulk UVC endpoint, bypassing AVFoundation.

The camera sends H.264 no matter which UVC format the host negotiates, which is
why QuickTime/AVFoundation stalls after ~2s. Reading the endpoint directly works.

usage: sudo python3 uvcgrab.py [SECONDS] | ffmpeg -f h264 -framerate 25 -i - -c copy out.mp4
Writes Annex-B H.264 to stdout and status to stderr. Needs pyusb and libusb
(pip install pyusb; brew install libusb) and root, because macOS's UVC driver
owns the interface otherwise.
"""
import signal
import struct
import sys
import time

import usb.backend.libusb1
import usb.core
import usb.util

VID, PID = 0x1D6B, 0x1110
VS_IFACE = 1
EP_IN = 0x81
H264_FORMAT_INDEX = 2
FRAME_INTERVAL = 400000  # 100ns units -> 25 fps

secs = float(sys.argv[1]) if len(sys.argv) > 1 else float("inf")


def log(*a, **kw):
    print(*a, file=sys.stderr, flush=True, **kw)


stop = False


def on_signal(*_):
    global stop
    stop = True


signal.signal(signal.SIGINT, on_signal)
signal.signal(signal.SIGTERM, on_signal)
signal.signal(signal.SIGPIPE, on_signal)

backend = usb.backend.libusb1.get_backend()
if backend is None:  # Homebrew's prefix isn't on the default search path
    backend = usb.backend.libusb1.get_backend(find_library=lambda _: "/opt/homebrew/lib/libusb-1.0.dylib")
dev = usb.core.find(idVendor=VID, idProduct=PID, backend=backend)
if dev is None:
    sys.exit("Thermal camera not found. Plug it in over USB-C and switch it on.")

try:
    if dev.is_kernel_driver_active(VS_IFACE):
        dev.detach_kernel_driver(VS_IFACE)
except usb.core.USBError as e:
    log("detach:", e)
usb.util.claim_interface(dev, VS_IFACE)


def get_probe(selector):
    return bytearray(dev.ctrl_transfer(0xA1, 0x81, selector << 8, VS_IFACE, 26))


def set_probe(selector, data):
    dev.ctrl_transfer(0x21, 0x01, selector << 8, VS_IFACE, data)


# UVC 1.0 probe/commit (26 bytes): bmHint, bFormatIndex, bFrameIndex, dwFrameInterval...
probe = get_probe(1)
probe[0:2] = b"\x01\x00"
probe[2] = H264_FORMAT_INDEX
probe[3] = 1
probe[4:8] = struct.pack("<I", FRAME_INTERVAL)
set_probe(1, probe)
probe = get_probe(1)
max_payload = struct.unpack("<I", probe[22:26])[0]
set_probe(2, probe)  # commit starts the stream

out = sys.stdout.buffer
t0 = time.time()
frames = 0
last_fid = None
started = False  # hold output until the first SPS so decoders get a clean start
try:
    while not stop and time.time() - t0 < secs:
        try:
            pkt = bytes(dev.read(EP_IN, max(max_payload, 16384), timeout=1000))
        except usb.core.USBTimeoutError:
            log(f"\nno data for 1s ({frames} frames so far)")
            continue
        if len(pkt) < 2:
            continue
        hlen, flags = pkt[0], pkt[1]
        data = pkt[hlen:]
        if not started:
            i = data.find(b"\x00\x00\x00\x01\x67")
            if i < 0:
                continue
            data = data[i:]
            started = True
        try:
            out.write(data)
        except BrokenPipeError:
            break
        fid = flags & 1
        if flags & 0x02 or (last_fid is not None and fid != last_fid):
            frames += 1
            if frames % 25 == 0:
                log(f"\r{frames / 25:7.1f}s recorded", end="")
        last_fid = fid
finally:
    log(f"\n{frames} frames")
    try:
        dev.clear_halt(EP_IN)
    except usb.core.USBError:
        pass
    usb.util.release_interface(dev, VS_IFACE)
