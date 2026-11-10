# mpv-multiloop
Loop over multiple A-B points in mpv.

![screenshot](/img/screenshot.png)

## Installation
Place `multiloop.lua` in your scripts folder, generally `~/.config/mpv/scripts/` (GNU/Linux) or `%AppData%\mpv\scripts\` (Windows), or start mpv with `--scripts=/path/to/multiloop.lua`.

## Usage
The script is activated by the M (shift+m) key. This can be changed by editing the `keybind` variable at the beginning of the file.

Follow the on-screen instructions.
If you save the A-B points, the script creates a JSON sidecar next to the media file. For example, `goor_dis.mp4` uses `goor_dis.mab.json`. The points are restored from this file when activating the script and can be reloaded with `r` after external edits.
New entries are selected by default, and loop playback visits only selected entries.

```json
{
  "version": 2,
  "mediaFileName": "goor_dis.mp4",
  "cutSegments": [
    {
      "start": 17.28,
      "end": 20.24,
      "name": "",
      "selected": true
    }
  ]
}
```

~~Once looping, to exit you'll have to quit mpv.~~

## Smart cut

`smart-cut.lua` joins the segments whose `selected` value is `true`. It probes
video keyframes, re-encodes only the non-keyframe-aligned edges, stream-copies
the middle of each segment, and concatenates all generated parts.

Install `smart-cut.lua` beside `multiloop.lua`, then create
`~/.config/mpv/script-opts/smart-cut.conf`:

```ini
output_file=~/Downloads/out.mkv
```

Relative output paths are resolved next to the current media file. Run the cut
with `Ctrl+Alt+c` or map `script-binding smart-cut` in `input.conf`. FFmpeg,
ffprobe, and ExifTool must be available on `PATH`. `~/` paths are expanded using the user's
home directory. If the configured output already exists, the script tries
`out01.mkv`, `out02.mkv`, and so on.

Source metadata is mapped into the output. ExifTool additionally copies all
writable metadata for MP4/MOV output, including explicit XMP `Relation` and
`Source` fields. Since ExifTool cannot write Matroska, these two XMP values are
stored as Matroska `RELATION` and `SOURCE` tags for MKV output.
