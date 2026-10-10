#!/usr/bin/env bash
#
# On-camera demos for the Orange Pi Zero 3W (A733): GPU + Cedar video engine.
# Every demo prints the exact command it runs.
#
#   ./demo.sh              menu
#   ./demo.sh <name>       run one demo: info gpu chrome decode encode transcode mpv all
#
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
M="$KIT_DIR/media"
export DISPLAY=${DISPLAY:-:0}

title() { printf '\n\033[1;35m━━━ %s ━━━\033[0m\n' "$*"; }
show()  { printf '\033[1;33m$ %s\033[0m\n' "$*"; }
run()   { show "$*"; eval "$@"; }
pause() { [ -n "${NOPAUSE:-}" ] || read -rp $'\n[enter] to continue ' _; }

# bench "label" ffmpeg-args...  -> frames, fps and CPU use (100% = one core)
bench() {
    local label=$1; shift
    show "ffmpeg $*"
    local out fr rt ut st
    out=$(ffmpeg -hide_banner -nostats -benchmark "$@" 2>&1)
    fr=$(grep -o 'frame= *[0-9]*' <<<"$out" | tail -1 | grep -o '[0-9]*')
    rt=$(grep -o 'rtime=[0-9.]*' <<<"$out" | cut -d= -f2)
    ut=$(grep -o 'utime=[0-9.]*' <<<"$out" | cut -d= -f2)
    st=$(grep -o 'stime=[0-9.]*' <<<"$out" | cut -d= -f2)
    if [ -z "$fr" ] || [ -z "$rt" ]; then
        printf '   \033[31m%s: failed\033[0m\n' "$label"; grep -i error <<<"$out" | head -3; return
    fi
    printf '   \033[1;32m%-34s %4d frames  %6.1f fps   CPU %4.0f%%\033[0m\n' "$label" "$fr" \
        "$(bc -l <<<"$fr/$rt")" "$(bc -l <<<"($ut+$st)/$rt*100")"
}

need_media() { [ -s "$M/$1" ] || { echo "missing $M/$1 - run setup.sh"; return 1; }; }

demo_info() {
    title "The board"
    run "(. /etc/orangepi-release; echo \"\$BOARD_NAME (\$BOARDFAMILY), Orange Pi OS \$VERSION \$DISTRIBUTION_CODENAME\"); uname -r; lscpu | grep -E 'Model name|^CPU\\(s\\)'; free -h | head -2"
    title "GPU: PowerVR BXM-4-64 (Imagination proprietary driver 24.2)"
    run "vulkaninfo --summary 2>/dev/null | grep -E 'apiVersion|deviceName|driverName|driverInfo' | head -4"
    run "es2_info 2>/dev/null | grep -E 'GL_VERSION|GL_RENDERER'"
    run "glxinfo -B 2>/dev/null | grep 'OpenGL renderer'   # desktop GL = software llvmpipe!"
    run "clinfo -l 2>/dev/null"
    title "Video engine: Allwinner Cedar (proprietary libcedarc, no V4L2)"
    run "ls -l /dev/cedar_dev /dev/cedar_dev_ve2; ls /dev/video* 2>&1 | head -1"
    run "ffmpeg -hide_banner -decoders | grep cedar; ffmpeg -hide_banner -encoders | grep cedar"
    title "PCIe (Gen3 x1 root port, enabled out of the box)"
    run "lspci; sudo lspci -vv -s 00:00.0 | grep -E 'LnkCap:|LnkSta:'"
}

demo_gpu() {
    title "OpenGL ES 3.2 on the PowerVR"
    run "glmark2-es2 -b shading:shading=phong:duration=5 -b texture:duration=5 -b refract:duration=5 2>&1 | grep -E 'RENDERER|FPS|Score'"
    title "Vulkan 1.3 on the PowerVR (close the window to continue)"
    run "timeout 15 vkcube >/dev/null 2>&1"
}

demo_chrome() {
    local page="file://$KIT_DIR/web/webgl-bench.html"
    # Separate profiles = separate browser processes, so both can run side by side.
    title "Chrome as shipped: desktop GL via GLX = llvmpipe, so the GPU is blocklisted"
    run "/opt/google/chrome/google-chrome --user-data-dir=/tmp/chrome-stock --no-first-run chrome://gpu $page >/dev/null 2>&1 &"
    echo "   -> chrome://gpu: everything 'Software only', GPU0 = llvmpipe; the WebGL page says unavailable"
    pause
    title "Chrome with ANGLE + Skia on the PowerVR Vulkan driver"
    run "/opt/google/chrome/google-chrome --use-angle=vulkan --enable-features=Vulkan --user-data-dir=/tmp/chrome-gpu --no-first-run chrome://gpu $page >/dev/null 2>&1 &"
    echo "   -> Canvas/Compositing/Rasterization/WebGL/WebGPU 'Hardware accelerated'"
    echo "      GPU0 = ANGLE (Imagination Technologies, Vulkan 1.3.277 (PowerVR B-Series BXM-4-64 MC1))"
    echo "   -> 'Video Acceleration Information' is empty: Chrome only knows VA-API/V4L2 and the Cedar"
    echo "      engine has neither, so video decodes on the CPU (the GPU still scales and composites)."
    echo "   (setup.sh made these flags the default for the normal 'google-chrome' launchers)"
}

demo_decode() {
    need_media bbb_1080_h265.mp4 || return
    title "Decoding: CPU (8 threads) vs Cedar VE"
    bench "1080p HEVC  software" -i "$M/bbb_1080_h265.mp4" -f null -
    bench "1080p HEVC  hevc_cedar" -c:v hevc_cedar -i "$M/bbb_1080_h265.mp4" -f null -
    bench "1080p VP9   software" -i "$M/bbb_1080_vp9.webm" -f null -
    bench "1080p VP9   vp9_cedar" -c:v vp9_cedar -i "$M/bbb_1080_vp9.webm" -f null -
    bench "1080p H.264 software" -i "$M/bbb_1080_h264.mp4" -f null -
    bench "1080p H.264 h264_cedar" -c:v h264_cedar -i "$M/bbb_1080_h264.mp4" -f null -
    if [ -s "$M/bbb_2160_hevc.mp4" ]; then
        bench "4K HEVC     software" -i "$M/bbb_2160_hevc.mp4" -f null -
        bench "4K HEVC     hevc_cedar" -c:v hevc_cedar -i "$M/bbb_2160_hevc.mp4" -f null -
    fi
    title "Bit-exact? Compare every decoded frame with FFmpeg's software decoder"
    show "ffmpeg -c:v hevc_cedar -i bbb_1080_h265.mp4 -f framemd5 hw.md5;  ffmpeg -i bbb_1080_h265.mp4 -pix_fmt nv12 -f framemd5 sw.md5"
    local t; t=$(mktemp -d)
    ffmpeg -hide_banner -loglevel error -c:v hevc_cedar -i "$M/bbb_1080_h265.mp4" -an -f framemd5 "$t/hw" </dev/null
    ffmpeg -hide_banner -loglevel error -i "$M/bbb_1080_h265.mp4" -an -pix_fmt nv12 -f framemd5 "$t/sw" </dev/null
    printf '   \033[1;32m%s of %s frames identical\033[0m\n' \
        "$(grep -v '^#' "$t/hw" | awk -F', *' '{print $6}' | grep -cxFf <(grep -v '^#' "$t/sw" | awk -F', *' '{print $6}'))" \
        "$(grep -vc '^#' "$t/sw")"
    rm -rf "$t"
}

demo_encode() {
    need_media bbb_1080_h264.mp4 || return
    title "Encoding 1080p: x264/x265 on the CPU vs Cedar VE (decode is HW in all cases)"
    bench "H.264 libx264 veryfast 6M" -c:v h264_cedar -i "$M/bbb_1080_h264.mp4" -c:v libx264 -preset veryfast -b:v 6M -f null -
    bench "H.264 h264_cedar 6M" -c:v h264_cedar -i "$M/bbb_1080_h264.mp4" -c:v h264_cedar -b:v 6M -f null -
    bench "HEVC  libx265 ultrafast 4M" -c:v h264_cedar -i "$M/bbb_1080_h264.mp4" -c:v libx265 -preset ultrafast -b:v 4M -f null -
    bench "HEVC  hevc_cedar 4M" -c:v h264_cedar -i "$M/bbb_1080_h264.mp4" -c:v hevc_cedar -b:v 4M -f null -
    title "Rate control options"
    run "ffmpeg -hide_banner -h encoder=hevc_cedar 2>/dev/null | sed -n '/AVOptions/,\$p' | grep -v Exiting"
}

demo_transcode() {
    need_media bbb_1080_vp9.webm || return
    title "Full hardware transcode: VP9 decode on VE, HEVC encode on VE2 (two engines)"
    run "ffmpeg -hide_banner -loglevel error -stats -y -c:v vp9_cedar -i $M/bbb_1080_vp9.webm -c:v hevc_cedar -b:v 4M -an /tmp/bbb_hevc.mp4"
    run "ffprobe -v error -show_entries stream=codec_name,width,height,bit_rate -of default=nw=1 /tmp/bbb_hevc.mp4"
    title "...streamed through a pipe (MPEG-TS to stdout)"
    run "ffmpeg -hide_banner -loglevel error -c:v hevc_cedar -i $M/bbb_1080_h265.mp4 -c:v h264_cedar -b:v 6M -f mpegts - | ffprobe -v error -count_frames -select_streams v -show_entries stream=codec_name,nb_read_frames -of csv=p=0 - | sort -u"
    if [ -s "$M/bbb_2160_hevc.mp4" ]; then
        title "4K HEVC -> 1080p H.264 (scaling on the CPU)"
        bench "4K HEVC -> 1080p H.264" -c:v hevc_cedar -i "$M/bbb_2160_hevc.mp4" -vf scale=1920:1080 -c:v h264_cedar -b:v 6M -f null -
    fi
}

demo_mpv() {
    local f="$M/bbb_2160_hevc.mp4"; [ -s "$f" ] || f="$M/bbb_1080_h265.mp4"
    local osd=(--osd-level=3 '--osd-status-msg=hwdec: ${hwdec-current}   dropped: ${frame-drop-count}   ${time-pos}')
    title "mpv, software decoding (stock)"
    show "mpv --fs $(basename "$f")"
    mpv --fs --length=12 "${osd[@]}" "$f" >/dev/null 2>&1
    title "mpv-cedar: Cedar decode -> DMA-BUF -> PowerVR (zero copy)"
    show "mpv-cedar --fs $(basename "$f")"
    mpv-cedar --fs --length=12 "${osd[@]}" "$f" >/dev/null 2>&1
    echo "   tip: press 'i' in mpv for its statistics page"
}

ALL=(info gpu chrome decode encode transcode mpv)
if [ $# -gt 0 ]; then
    for d in "$@"; do
        if [ "$d" = all ]; then for a in "${ALL[@]}"; do "demo_$a"; pause; done
        elif declare -F "demo_$d" >/dev/null; then "demo_$d"
        else echo "unknown demo '$d' (choose: ${ALL[*]} all)"; exit 1; fi
    done
    exit 0
fi
PS3=$'\nDemo? '
select d in "${ALL[@]}" all quit; do
    case $d in
        quit|"") break ;;
        all) for a in "${ALL[@]}"; do "demo_$a"; pause; done ;;
        *) "demo_$d" ;;
    esac
done
