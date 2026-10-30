# mpv-multiloop
Loop over multiple A-B points in mpv.

![screenshot](/img/screenshot.png)

## Installation
Place `multiloop.lua` in your scripts folder, generally `~/.config/mpv/scripts/` (GNU/Linux) or `%AppData%\mpv\scripts\` (Windows), or start mpv with `--scripts=/path/to/multiloop.lua`.

## Usage
The script is activated by the M (shift+m) key. This can be changed by editing the `keybind` variable at the beginning of the file.

Follow the on-screen instructions.
If you save the A-B points, the script creates a JSON sidecar next to the media file. For example, `goor_dis.mp4` uses `goor_dis.mab.json`. The points are restored from this file when activating the script and can be reloaded with `r` after external edits.

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
