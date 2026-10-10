# Orange Pi Zero 3W: GPU and hardware video on Orange Pi OS "Resolute"

These notes cover the Orange Pi Zero 3W (Allwinner **A733**: 2× Cortex-A76 and 6× Cortex-A55, 6 GB) running
**Orange Pi OS 1.0.2 Resolute** (Ubuntu 26.04) with the vendor **6.6.98-sun60iw2** kernel.

```
./setup.sh     # fresh install -> everything below (~20 min, mostly compiling FFmpeg)
./demo.sh      # menu of on-camera demos (info gpu chrome decode encode transcode mpv)
```

## What the hardware is and how the OS exposes it

| Block | Hardware | Driver/userspace on this image | Exposed as |
|---|---|---|---|
| GPU | Imagination **PowerVR B-Series BXM-4-64 MC1** | `pvrsrvkm` kernel module + IMG DDK **24.2** (closed) | `/dev/dri/card1`, `renderD128` |
| Display | Allwinner DE | `sunxi-drm` | `/dev/dri/card0` (HDMI, DP) |
| Video decode | Cedar VE | `sunxi_ve` + **libcedarc 1.0.7** (closed) | `/dev/cedar_dev` |
| Video encode | Cedar VE2 (a separate engine) | same | `/dev/cedar_dev_ve2` |
| PCIe | Gen3 ×1 root port | enabled in the DT (`pcie@6000000`) | `00:00.0` bridge; link trains when a device is attached |

There is **no V4L2 codec device** (`/dev/video*`) and **no VA-API driver**. The video engine is reachable only
through Allwinner's proprietary `libvdecoder`/`libvencoder` (or their OpenMAX wrapper used by `gst-omx`).
That is why the stock FFmpeg, Chrome and mpv cannot use it, and why this kit patches FFmpeg.

## GPU: what works and what doesn't

| API | Status |
|---|---|
| **OpenGL ES 3.2** (EGL: X11, GBM, surfaceless) | ✅ hardware: `es2_info`, `glmark2-es2` (≈435 score), mpv `--gpu-context=x11egl` |
| **Vulkan 1.3** | ✅ hardware: `vulkaninfo`, `vkcube`, Chrome/ANGLE, mpv |
| **OpenCL 3.0** | ✅ present (`clinfo`), and FFmpeg's `*_opencl` filters run, but slowly (blur 11 fps at 1080p). Not worth using for video. |
| EGL dma-buf import | ✅ `EGL_EXT_image_dma_buf_import(_modifiers)`, which makes zero-copy video possible |
| Desktop OpenGL / GLX | ❌ **software only** (Mesa llvmpipe). The PowerVR driver does not provide desktop GL. Anything that insists on GLX runs on the CPU. |
| Vulkan Video (decode/encode) | ❌ not exposed by the IMG driver |

### Chrome
Stock Chrome uses ANGLE on desktop GL through GLX. Here that's llvmpipe, so Chrome blocklists the GPU and **everything is
"Software only"**, with WebGL disabled.

Running ANGLE and Skia on the PowerVR **Vulkan** driver instead works well:

```
google-chrome --use-angle=vulkan --enable-features=Vulkan
```

* `chrome://gpu`: Canvas, Compositing, Rasterization, **WebGL, WebGPU = Hardware accelerated**;
  GPU0 = `ANGLE (Imagination Technologies, Vulkan 1.3.277 (PowerVR B-Series BXM-4-64 MC1))`
* WebGL test page (`web/webgl-bench.html`, 1920×962): **≈50 fps on the PowerVR** vs **4 fps** in SwiftShader on the CPU
* `--use-angle=vulkan` alone leaves compositing in software, so you need both flags.
* Trap: `--use-angle=gles --ignore-gpu-blocklist` makes `chrome://gpu` say "Hardware accelerated", but GPU0 shows
  it is really llvmpipe. Always check the GPU0 line.
* **Video decode in Chrome stays on the CPU.** Chrome on Linux only does hardware decode through VA-API or V4L2, and the
  Cedar VE has neither ("Video Acceleration Information" is empty). The 8 cores still play 1080p30 H.264/VP9/AV1
  with no dropped frames; the GPU does the scaling and compositing.

`setup.sh` makes these flags the default (menu launcher plus `PATH` wrappers). They only apply when no Chrome process
is already running.

## Hardware video: FFmpeg with Allwinner Cedar codecs

`patches/ffmpeg-8.0.1-cedar.patch` adds native libcedarc codecs to FFmpeg 8.0.1:

| Codec | Name | Notes |
|---|---|---|
| H.264 decode | `h264_cedar` | **bit-exact** with FFmpeg's software decoder (300/300 frame MD5s) |
| HEVC decode | `hevc_cedar` | bit-exact, 8-bit |
| VP9 decode | `vp9_cedar` | bit-exact |
| VP8 decode | `vp8_cedar` | bit-exact |
| MPEG-2 / MPEG-4 Part 2 decode | `mpeg2_cedar`, `mpeg4_cedar` | |
| H.264 encode | `h264_cedar` | High profile, CBR or constant QP |
| HEVC encode | `hevc_cedar` | Main profile, CBR or constant QP |

Decoders output **NV12** by default. When the caller asks for hardware frames, they output zero-copy **DRM_PRIME**
(dma-buf) frames; that's how `mpv --hwdec=cedar` works. AV1 has no hardware decoder on this chip (dav1d is used).

FFmpeg is installed in `/opt/ffmpeg-cedar` as shared libraries, with `ffmpeg`/`ffprobe`/`ffplay` symlinked into
`/usr/local/bin`. The distro's FFmpeg libraries, which Chrome and others use, are untouched.

### Usage
```bash
# decode
ffmpeg -c:v hevc_cedar -i in.mp4 -f null -
# encode (rate control: -b:v for CBR, or -rc_mode cqp -qp 24)
ffmpeg -i in.mkv -c:v h264_cedar -b:v 6M out.mp4
ffmpeg -i in.mkv -c:v hevc_cedar -rc_mode cqp -qp 26 out.mkv
# all-hardware transcode (decode on VE, encode on VE2)
ffmpeg -c:v vp9_cedar -i in.webm -c:v hevc_cedar -b:v 4M -c:a copy out.mkv
# streaming to stdout works too
ffmpeg -c:v hevc_cedar -i in.mp4 -c:v h264_cedar -b:v 6M -f mpegts - | ...
# zero-copy playback on the desktop
mpv-cedar video.mp4            # = mpv --hwdec=cedar --vo=gpu --gpu-context=x11egl
mpv-cedar --hwdec=cedar-copy video.mp4
```
The `*_cedar` decoders must be selected explicitly with `-c:v`. Plain `ffmpeg -i` still uses the software decoders.

### Benchmarks (measured on this board)

FFmpeg, 10 s Big Buck Bunny clips. CPU is total utime+stime over wall time (100% = one core).

| Test | Software | Cedar |
|---|---|---|
| 1080p HEVC decode | 68 fps @ 537% CPU | **147 fps @ 59%** |
| 1080p VP9 decode | 86 fps @ 574% | **109 fps @ 33%** |
| 1080p H.264 decode | 107 fps @ 683% | **91 fps @ 36%** |
| 4K HEVC decode | 35 fps @ 710% | **57 fps @ 45%** |
| 1080p H.264 encode | 39 fps @ 627% (x264 veryfast) | **87 fps @ 63%** |
| 1080p HEVC encode | 8.5 fps (x265 ultrafast) | **87 fps @ 58%** |
| 4K encode (synthetic) | – | H.264 ≈31 fps, HEVC ≈39 fps |

mpv, playing fullscreen on the desktop (mpv process CPU, 100% = one core):

| Clip | `--hwdec=no` | `cedar-copy` | `cedar` (zero-copy) |
|---|---|---|---|
| 4K HEVC | 130% | 30% | **20%** |
| 1080p HEVC | 211% | 43% | **31%** |

Quality: the VE encoder is a fast, simple encoder. At equal bitrate it scores below x264/x265
(1080p BBB at 6 Mb/s: PSNR-Y 34.4 dB vs x264 veryfast 38.2 dB), so give it about 1.5–2× the bitrate, or use `-rc_mode cqp`.

### Vendor-library quirks found (and handled in the patch)
1. **Encode height must be a multiple of 16**, otherwise the VE never raises its interrupt ("wait interrupt
   overtime"). Also, a smaller `nDstWidth/nDstHeight` makes the VE **scale** (not crop), which blurs 1080p badly.
   The encoder therefore codes 1920×1088 and rewrites the crop into the SPS with FFmpeg's CBS.
2. `VENC_IndexParamSpecCropInfo` is accepted but ignored.
3. **Main/Baseline H.264 profiles are broken:** the headers omit `transform_8x8_mode` (and CABAC) while the VE still
   codes High-profile slices, so the output won't decode. Only High is offered.
4. **VBR rate control is broken:** it ignores bitrate and quality settings (always about 1 Mb/s). Only CBR and constant QP are offered.
5. Codec parameters must be set **before** `VideoEncInit`; afterwards they are silently ignored.
6. The decoder deadlocks after about 12 frames unless `nDecodeSmoothFrameBufferNum` > 0.
7. libcedarc `printf`s its debug log to **stdout**, corrupting piped output. `setup.sh` sets `cdc_log_level = 7`
   in `/etc/cedarc.conf`, and the codecs also lower libcedarc's shared `GLOBAL_LOG_LEVEL`.

### GStreamer
The preinstalled `gst-omx` also reaches the VE (`omxh264dec`, `omxhevcvideodec`, `omxvp9videodec`,
`omxh264videoenc`, `omxhevcvideoenc`, …), for example:
```
gst-launch-1.0 videotestsrc num-buffers=300 ! video/x-raw,width=1920,height=1080,format=NV12 ! omxh264videoenc ! h264parse ! mp4mux ! filesink location=test.mp4
```

## Chrome: why not chrome://flags?
On Linux, Chrome has no `chrome://flags` entry for the ANGLE backend (setting `use-angle` in `Local State` has no effect), so
`--use-angle=vulkan` has to be on the command line. `setup.sh` covers both launch paths: the menu entry
(`~/.local/share/applications/google-chrome.desktop`) and anything that finds Chrome through `PATH`, including
XFCE's "Web Browser" helper (wrappers in `/usr/local/bin`). `chrome://flags/#enable-vulkan` does exist, but it isn't enough on its own.

## Undo
```bash
sudo rm -rf /opt/ffmpeg-cedar /usr/local/bin/{ffmpeg,ffprobe,ffplay,mpv-cedar,google-chrome,google-chrome-stable} \
           /usr/share/applications/mpv-cedar.desktop
rm -f ~/.local/share/applications/google-chrome.desktop
sudo cp /etc/cedarc.conf.orig /etc/cedarc.conf
```

## Licensing note
The patch itself is LGPL-2.1+ like FFmpeg. The resulting FFmpeg build (GPL, because of x264/x265) links Allwinner's
proprietary libcedarc, so **don't redistribute the binaries**. Build them on the board, as `setup.sh` does.
