#!/usr/bin/env bash
# Accurate, minimally re-encoded video cuts. See README.md for limitations.
set -Eeuo pipefail
export LC_ALL=C
usage() { echo "Usage: ${0##*/} INPUT_FILE OUTPUT_FILE -k|--keep START,STOP[,START,STOP...]"; }
die() { echo "Error: $*" >&2; exit 1; }
args=(); keep=''
while (($#)); do
    case "$1" in
        -k|--keep) (($# >= 2)) || die "$1 needs a comma-separated value"; [[ -z $keep ]] || die 'Specify --keep once'; keep=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        --) shift; args+=("$@"); break ;;
        -*) die "Unknown option: $1" ;;
        *) args+=("$1"); shift ;;
    esac
done
((${#args[@]} == 2)) && [[ -n $keep ]] || { usage >&2; exit 1; }
for tool in ffmpeg ffprobe python3 exiftool; do command -v "$tool" >/dev/null || die "Missing dependency: $tool"; done
input=$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "${args[0]}")
output=$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "${args[1]}")
[[ -f $input ]] || die "Input is not a regular file: $input"
[[ $input != "$output" && ! $input -ef $output ]] || die "Input and output must be different files"
[[ ! -d $output ]] || die "Output is a directory: $output"
[[ -d ${output%/*} ]] || die 'Output directory does not exist'
tmp=$(mktemp -d)
staged=''
cleanup() { rm -rf -- "$tmp"; [[ -z $staged ]] || rm -f -- "$staged"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
ffprobe -v error -show_streams -show_format -of json "$input" > "$tmp/probe.json"
# Packet K flags identify random-access points; pict_type=I does not.
ffprobe -v error -select_streams v:0 -show_packets -show_entries packet=pts_time,flags -of json "$input" > "$tmp/packets.json"
python3 - "$tmp" "$keep" <<'PY'
import json, sys, re
from pathlib import Path
p = Path(sys.argv[1])
def fail(s): sys.exit('Error: ' + s)
def timestamp(s):
    # FFmpeg duration syntax, normalized with its microsecond truncation.
    value = s.strip()
    clock = re.fullmatch(
        r"(-?)(?:([0-9]+):)?([0-5]?[0-9]):([0-5]?[0-9])"
        r"(?:\.([0-9]*))?(s|ms|us)?", value)
    if clock:
        sign, hours, minutes, seconds, fraction, suffix = clock.groups()
        whole = int(hours or 0) * 3600 + int(minutes) * 60 + int(seconds)
    else:
        seconds = re.fullmatch(r"(-?)([+]?[0-9]+)(?:\.([0-9]*))?(s|ms|us)?", value)
        if not seconds: fail('Invalid timestamp: ' + repr(s))
        sign, whole, fraction, suffix = seconds.groups()
        try:
            whole = int(whole)
        except ValueError:
            fail('Timestamp is too large: ' + repr(s))
    try:
        scale = {'s': 1000000, 'ms': 1000, 'us': 1, None: 1000000}[suffix]
        fractional_us = int(((fraction or '') + '000000')[:6])
        microseconds = int(whole) * scale + fractional_us * scale // 1000000
    except ValueError:
        fail('Timestamp is too large: ' + repr(s))
    if microseconds > 9223372036854775807:
        fail('Timestamp is too large: ' + repr(s))
    return (-microseconds if sign else microseconds) / 1000000
meta = json.loads((p/'probe.json').read_text())
videos = [s for s in meta['streams'] if s['codec_type']=='video' and not s.get('disposition',{}).get('attached_pic')]
if not videos or videos[0]['index'] != next(s['index'] for s in meta['streams'] if s['codec_type']=='video'): fail('A first video stream without cover art is required')
v = videos[0]
origin = float(meta['format'].get('start_time',0))
duration = float(meta['format']['duration'])
values = sys.argv[2].split(',')
if len(values)%2: fail('--keep requires an even number of comma-separated timestamps')
points = list(map(timestamp, values))
keys = sorted(set(float(x['pts_time'])-origin for x in json.loads((p/'packets.json').read_text())['packets'] if 'K' in x.get('flags','') and 'pts_time' in x))
with (p/'ranges').open('w') as ranges, (p/'plan').open('w') as plan:
    for start, stop in zip(points[::2],points[1::2]):
        if not 0 <= start < stop <= duration + 0.000001: fail('Each range must satisfy 0 <= START < STOP <= input duration')
        ranges.write(f'{start:.9f} {stop:.9f}\n')
        inside = [k for k in keys if start <= k <= stop]
        if len(inside)<2:
            plan.write(f'encode {start:.9f} {stop-start:.9f}\n')
        else:
            first,last = inside[0],inside[-1]
            if first>start: plan.write(f'encode {start:.9f} {first-start:.9f}\n')
            plan.write(f'copy {first:.9f} {last-first:.9f}\n')
            if stop>last: plan.write(f'encode {last:.9f} {stop-last:.9f}\n')
(p/'video').write_text('\n'.join(str(x) for x in [v['codec_name'],v.get('pix_fmt','yuv420p'),v.get('bit_rate','0')]))
(p/'audio').write_text('yes' if any(s['codec_type']=='audio' for s in meta['streams']) else 'no')
PY
mapfile -t video < "$tmp/video"
codec=${video[0]}; pixfmt=${video[1]}; bitrate=${video[2]}
encoders=$(ffmpeg -hide_banner -encoders 2>/dev/null)
has_encoder() { awk -v name="$1" '$2 == name {found=1} END {exit !found}' <<< "$encoders"; }
# MPEG-TS carries fresh parameter sets at joins, unlike MP4 sample entries.
mode=hybrid
case "$codec" in
    h264) encoder=libx264 ;;
    hevc) encoder=libx265 ;;
    mpeg2video) encoder=mpeg2video ;;
    vp8) encoder=libvpx ;;
    vp9) encoder=libvpx-vp9 ;;
    av1) encoder=libaom-av1 ;;
    *) encoder=$codec ;;
esac
if ! has_encoder "$encoder"; then
    mode=full; encoder=libx264
    has_encoder "$encoder" || die 'No suitable source encoder or libx264 fallback is installed'
    echo "Source encoder unavailable; encoding all selected video as H.264." >&2
fi
if [[ $mode == full ]]; then
    echo "Using full-fragment encoding ($encoder) for compatible concatenation." >&2
    awk '{printf "encode %s %.9f\n", $1, $2-$1}' "$tmp/ranges" > "$tmp/plan"
fi
encoding=(-c:v "$encoder" -pix_fmt "$pixfmt")
if [[ $encoder == libx264 || $encoder == libx265 ]]; then
    encoding+=(-preset medium)
    if [[ $bitrate =~ ^[0-9]+$ ]] && ((bitrate > 0)); then encoding+=(-b:v "$bitrate"); else encoding+=(-crf 18); fi
    [[ $encoder != libx264 ]] || encoding+=(-x264-params 'open-gop=0:repeat-headers=1')
    [[ $encoder != libx265 ]] || encoding+=(-x265-params 'open-gop=0:repeat-headers=1:log-level=error')
elif [[ $bitrate =~ ^[0-9]+$ ]] && ((bitrate > 0)); then
    encoding+=(-b:v "$bitrate")
fi
index=0
while read -r action start length; do
    printf '%s video at %s for %s seconds\n' "$action" "$start" "$length" >&2
    name=$(printf 'part-%06d' "$index")
    case "$codec:$mode" in
        h264:hybrid|hevc:hybrid|mpeg2video:hybrid) ext=ts; container=mpegts ;;
        *) ext=mkv; container=matroska ;;
    esac
    opts=(-c:v copy -bsf:v "noise=drop=gte(pts*tb\,$length)")
    [[ $action != encode ]] || opts=("${encoding[@]}")
    ffmpeg -nostdin -hide_banner -loglevel warning -ss "$start" -i "$input" -t "$length" -map 0:v:0 -an -sn -dn "${opts[@]}" -avoid_negative_ts make_zero -f "$container" "$tmp/$name.$ext"
    printf "file '%s.%s'\n" "$name" "$ext" >> "$tmp/video-list"
    printf "duration %s\n" "$length" >> "$tmp/video-list"
    index=$((index+1))
done < "$tmp/plan"
# Audio is trimmed once per user range, independently of video GOP boundaries.
audio_opts=(-an)
if [[ $(cat "$tmp/audio") == yes ]]; then
    filter=''; labels=''; index=0
    while read -r start stop; do
        filter+="[0:a:0]aresample=async=1:first_pts=0,atrim=start=$start:end=$stop,asetpts=PTS-STARTPTS[a$index];"
        labels+="[a$index]"; index=$((index+1))
    done < "$tmp/ranges"
    filter+="${labels}concat=n=$index:v=0:a=1[out]"
    ffmpeg -nostdin -hide_banner -loglevel warning -i "$input" -filter_complex "$filter" -map '[out]' -c:a pcm_s24le "$tmp/audio.mka"
    audio_opts=(-i "$tmp/audio.mka" -map 0:v:0 -map 1:a:0 -c:a aac -b:a 192k)
fi
# Build beside the destination; publish only after muxing and metadata copying succeed.
staged=$(mktemp "${output%/*}/.cut-video.XXXXXXXX")
# Keep the destination suffix so ffmpeg can select its muxer.
staged_suffix="$staged.${output##*.}"
mv -- "$staged" "$staged_suffix"; staged=$staged_suffix
ffmpeg -nostdin -hide_banner -loglevel warning -f concat -safe 1 -i "$tmp/video-list" "${audio_opts[@]}" -c:v copy -map_metadata -1 -y "$staged"
exiftool -overwrite_original -TagsFromFile "$input" -EXIF:All -XMP:All "$staged"
mv -fT -- "$staged" "$output"
staged=''
printf 'Created %s\n' "$output"
