#!/usr/bin/env bash
#
# Orange Pi Zero 3W (Allwinner A733, PowerVR BXM-4-64 GPU, Cedar VE)
# Orange Pi OS 1.0.2 "Resolute" (Ubuntu 26.04), kernel 6.6 BSP
#
# Takes a fresh install to:
#   * FFmpeg 8.0.1 with Allwinner Cedar hardware codecs
#       decoders: h264_cedar hevc_cedar vp9_cedar vp8_cedar mpeg2_cedar mpeg4_cedar
#       encoders: h264_cedar hevc_cedar
#     installed in /opt/ffmpeg-cedar, with ffmpeg/ffprobe/ffplay linked into
#     /usr/local/bin (the distro's own FFmpeg libraries are left untouched)
#   * mpv-cedar: the stock mpv using those libraries for zero-copy HW playback
#   * Google Chrome launched on the PowerVR GPU through Vulkan
#   * demo clips in ~/cedar-demo/media
#
# Usage:   ./setup.sh            (run as your normal user; it calls sudo)
# Re-running is safe: finished steps are skipped.
#
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH="$KIT_DIR/patches/ffmpeg-8.0.1-cedar.patch"
BUILD_DIR="$KIT_DIR/build"
MEDIA_DIR="$KIT_DIR/media"
PREFIX=/opt/ffmpeg-cedar

FFMPEG_VER=8.0.1
FFMPEG_URL="https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VER.tar.xz"
FFMPEG_SHA256=05ee0b03119b45c0bdb4df654b96802e909e0a752f72e4fe3794f487229e5a41

step() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '    \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -ne 0 ] || die "run this as your normal user, not root (it uses sudo where needed)"

# ---------------------------------------------------------------- 0. checks
step "Checking the board and the vendor video stack"
[ "$(uname -m)" = aarch64 ] || die "this is for the arm64 Orange Pi OS image"
grep -q sun60iw2 /proc/device-tree/compatible 2>/dev/null ||
    warn "SoC is not sun60iw2 (A733); continuing, but this was only tested on A733"
for f in /usr/include/vdecoder.h /usr/include/vencoder.h \
         /usr/lib/aarch64-linux-gnu/libvdecoder.so /usr/lib/aarch64-linux-gnu/libvencoder.so; do
    [ -e "$f" ] || die "$f missing - the Orange Pi libcedarc package (libcedarc-dev-2.0.0-arm64) is required"
done
ok "libcedarc $(dpkg-query -W -f='${Version}' libcedarc-dev-2.0.0-arm64 2>/dev/null || echo '?') present"
[ -e /dev/cedar_dev ] && [ -e /dev/cedar_dev_ve2 ] ||
    die "/dev/cedar_dev or /dev/cedar_dev_ve2 missing - is the sunxi_ve driver loaded?"
ok "Cedar decoder (/dev/cedar_dev) and encoder (/dev/cedar_dev_ve2) nodes present"
[ -f "$PATCH" ] || die "missing $PATCH"

# Some A733 images make the encoder node root-only; make both usable by 'video'.
if ! [ -r /dev/cedar_dev_ve2 ] || ! [ -w /dev/cedar_dev_ve2 ]; then
    step "Granting the video group access to the Cedar encoder"
    echo 'SUBSYSTEM=="cedar_ve2", KERNEL=="cedar_dev_ve2", GROUP="video", MODE="0660"' |
        sudo tee /etc/udev/rules.d/99-cedar-ve2.rules >/dev/null
    sudo udevadm control --reload-rules
    sudo udevadm trigger --sysname-match=cedar_dev_ve2
    sudo usermod -aG video "$USER"
    warn "added $USER to 'video' - log out and back in if encoding reports a permission error"
fi

# ---------------------------------------------------------------- 1. packages
step "Installing build dependencies and demo tools"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    build-essential nasm pkg-config wget xz-utils patch \
    libdrm-dev libx264-dev libx265-dev libdav1d-dev libvpx-dev libopus-dev \
    libmp3lame-dev libass-dev libfreetype-dev libharfbuzz-dev libfribidi-dev \
    libsdl2-dev libpulse-dev libasound2-dev libgnutls28-dev libv4l-dev \
    ocl-icd-opencl-dev opencl-c-headers \
    mpv mesa-utils vulkan-tools clinfo glmark2-es2 bc >/dev/null
ok "packages installed"

# ---------------------------------------------------------------- 2. vendor log
# libcedarc printf()s its debug log to *stdout*, which corrupts piped FFmpeg
# output (ffmpeg ... -f mpegts - | ...). Raise its threshold above ERROR.
step "Silencing libcedarc's stdout logging"
if grep -q '^cdc_log_level *= *7' /etc/cedarc.conf; then
    ok "already set"
else
    [ -f /etc/cedarc.conf.orig ] || sudo cp /etc/cedarc.conf /etc/cedarc.conf.orig
    sudo sed -i 's/^cdc_log_level *=.*/cdc_log_level = 7/' /etc/cedarc.conf
    ok "cdc_log_level = 7 in /etc/cedarc.conf (original saved as /etc/cedarc.conf.orig)"
fi

# ---------------------------------------------------------------- 3. FFmpeg
step "Building FFmpeg $FFMPEG_VER with Cedar hardware codecs"
if [ -x "$PREFIX/bin/ffmpeg" ] && grep -q hevc_cedar <<<"$("$PREFIX/bin/ffmpeg" -hide_banner -encoders 2>/dev/null)"; then
    ok "already installed in $PREFIX (delete it to force a rebuild)"
else
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"
    [ -f "ffmpeg-$FFMPEG_VER.tar.xz" ] || wget -q --show-progress "$FFMPEG_URL"
    echo "$FFMPEG_SHA256  ffmpeg-$FFMPEG_VER.tar.xz" | sha256sum -c --quiet ||
        die "checksum mismatch for ffmpeg-$FFMPEG_VER.tar.xz"
    rm -rf "ffmpeg-$FFMPEG_VER"
    tar xf "ffmpeg-$FFMPEG_VER.tar.xz"
    cd "ffmpeg-$FFMPEG_VER"
    patch -p1 -s < "$PATCH"
    ok "Cedar patch applied"

    ./configure \
        --prefix="$PREFIX" --enable-shared --disable-static --enable-rpath \
        --extra-version=cedar --disable-doc \
        --enable-gpl --enable-cedar --enable-libdrm --enable-opencl \
        --enable-libx264 --enable-libx265 --enable-libdav1d --enable-libvpx \
        --enable-libmp3lame --enable-libopus --enable-libass \
        --enable-libfreetype --enable-libharfbuzz --enable-libfribidi \
        --enable-gnutls --enable-sdl2 --enable-libpulse >configure.log 2>&1 ||
        { tail -20 configure.log; die "configure failed (see $PWD/configure.log)"; }
    ok "configured; compiling on $(nproc) cores (about 15 minutes)"
    make -j"$(nproc)" >make.log 2>&1 ||
        { tail -30 make.log; die "build failed (see $PWD/make.log)"; }
    sudo make install >install.log 2>&1
    ok "installed to $PREFIX"
fi
for b in ffmpeg ffprobe ffplay; do
    sudo ln -sf "$PREFIX/bin/$b" "/usr/local/bin/$b"
done
hash -r
ok "ffmpeg/ffprobe/ffplay -> $PREFIX/bin (first in PATH via /usr/local/bin)"

# ---------------------------------------------------------------- 4. mpv
step "Installing mpv-cedar (stock mpv + Cedar FFmpeg, zero-copy to the GPU)"
sudo tee /usr/local/bin/mpv-cedar >/dev/null <<EOF
#!/bin/sh
# mpv with Allwinner Cedar hardware decoding: decoded frames stay in DMA-BUFs
# and are imported straight into the PowerVR GPU (EGL dma-buf interop).
# Use --hwdec=cedar-copy to copy frames back to RAM instead.
export LD_LIBRARY_PATH=$PREFIX/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}
exec mpv --hwdec=cedar --vo=gpu --gpu-context=x11egl "\$@"
EOF
sudo chmod 755 /usr/local/bin/mpv-cedar
sudo tee /usr/share/applications/mpv-cedar.desktop >/dev/null <<'EOF'
[Desktop Entry]
Type=Application
Name=mpv (Cedar hardware decoding)
Comment=Play videos with the Allwinner video engine and PowerVR GPU
Exec=mpv-cedar --player-operation-mode=pseudo-gui -- %U
Icon=mpv
Terminal=false
Categories=AudioVideo;Video;Player;
MimeType=video/mp4;video/x-matroska;video/webm;video/mpeg;video/quicktime;video/x-msvideo;
EOF
ok "mpv-cedar installed (also in the desktop menu as 'mpv (Cedar hardware decoding)')"

# ---------------------------------------------------------------- 5. Chrome
# Stock Chrome tries desktop OpenGL via GLX, which on this board is Mesa's
# software llvmpipe, so it blocklists the GPU and renders everything on the
# CPU. Pointing ANGLE and Skia at the PowerVR Vulkan driver fixes that.
CHROME_FLAGS="--use-angle=vulkan --enable-features=Vulkan"
step "Enabling GPU acceleration in Google Chrome ($CHROME_FLAGS)"
if [ -x /opt/google/chrome/google-chrome ]; then
    # Menu launchers use the absolute /usr/bin path: override them per user.
    mkdir -p "$HOME/.local/share/applications"
    sed -E "s#^(Exec=/usr/bin/google-chrome-stable)( |$)#\1 $CHROME_FLAGS\2#" \
        /usr/share/applications/google-chrome.desktop \
        > "$HOME/.local/share/applications/google-chrome.desktop"
    ok "menu launcher: ~/.local/share/applications/google-chrome.desktop"
    # Terminal and XFCE's "Web Browser" helper find Chrome through PATH.
    for b in google-chrome google-chrome-stable; do
        sudo tee "/usr/local/bin/$b" >/dev/null <<EOF
#!/bin/sh
# Run Chrome's ANGLE + Skia on the PowerVR Vulkan driver (GLX here is software only).
exec /opt/google/chrome/google-chrome $CHROME_FLAGS "\$@"
EOF
        sudo chmod 755 "/usr/local/bin/$b"
    done
    ok "PATH wrappers: /usr/local/bin/google-chrome{,-stable}"
    warn "fully quit Chrome, then start it again; check chrome://gpu"
else
    warn "Google Chrome is not installed; skipped"
fi

# ---------------------------------------------------------------- 6. media
step "Downloading demo clips (Big Buck Bunny, 1080p, 10 s each)"
mkdir -p "$MEDIA_DIR"
cd "$MEDIA_DIR"
for spec in mp4/h264:bbb_1080_h264.mp4 mp4/h265:bbb_1080_h265.mp4 \
            webm/vp9:bbb_1080_vp9.webm webm/vp8:bbb_1080_vp8.webm webm/av1:bbb_1080_av1.webm; do
    path=${spec%%:*}; file=${spec#*:}; ext=${file##*.}
    [ -s "$file" ] || wget -q -O "$file" \
        "https://test-videos.co.uk/vids/bigbuckbunny/$path/1080/Big_Buck_Bunny_1080_10s_30MB.$ext" ||
        warn "could not download $file"
done
# 4K HEVC made on the board itself: HW decode -> CPU scale -> HW encode.
if [ ! -s bbb_2160_hevc.mp4 ] && [ -s bbb_1080_h264.mp4 ]; then
    ffmpeg -hide_banner -loglevel error -c:v h264_cedar -i bbb_1080_h264.mp4 \
        -vf scale=3840:2160 -c:v hevc_cedar -b:v 20M -an bbb_2160_hevc.mp4
fi
ok "$(ls "$MEDIA_DIR" | wc -l) clips in $MEDIA_DIR"

# ---------------------------------------------------------------- 7. verify
step "Verifying"
ffmpeg -hide_banner -version | head -1 | sed 's/^/    /'
decoders=$(ffmpeg -hide_banner -decoders 2>/dev/null)
encoders=$(ffmpeg -hide_banner -encoders 2>/dev/null)
for c in h264_cedar hevc_cedar vp9_cedar vp8_cedar; do
    grep -q " $c " <<<"$decoders" && ok "decoder $c" || warn "decoder $c missing"
done
for c in h264_cedar hevc_cedar; do
    grep -q " $c " <<<"$encoders" && ok "encoder $c" || warn "encoder $c missing"
done
if [ -s "$MEDIA_DIR/bbb_1080_h265.mp4" ]; then
    n=$(ffmpeg -hide_banner -loglevel error -c:v hevc_cedar -i "$MEDIA_DIR/bbb_1080_h265.mp4" \
            -c:v h264_cedar -b:v 6M -f mpegts - 2>/dev/null |
        ffprobe -v error -count_frames -select_streams v -show_entries stream=nb_read_frames -of csv=p=0 - 2>/dev/null |
        head -1)
    [ "${n:-0}" -eq 300 ] && ok "HEVC -> H.264 hardware transcode through a pipe: 300/300 frames" ||
        warn "hardware transcode test produced ${n:-0}/300 frames"
fi
vulkaninfo --summary 2>/dev/null | grep -m1 deviceName | sed 's/^ */    GPU (Vulkan): /'
DISPLAY=${DISPLAY:-:0} es2_info 2>/dev/null | grep -m1 GL_RENDERER | sed 's/^/    GPU (GLES):   /' || true

step "Done. Try:  $KIT_DIR/demo.sh"
