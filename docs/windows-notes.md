# OLAF on Windows

Getting the command line olaf application to work on Windows requires a few steps.

## Installing dependencies: ffmpeg

ffmpeg (and ffprobe, used by `--fragmented`) need to be installed on your system and **available on your path**.

For ffmpeg you need to copy `ffmpeg.exe` to e.g. `c:\windows\system32` or another location on your `$PATH`. You can find [recent ffmpeg builds for Windows here](https://github.com/BtbN/FFmpeg-Builds/releases) or [here](https://www.gyan.dev/ffmpeg/builds/). Download, unzip and copy the executables: `ffmpeg.exe` and `ffprobe.exe` are needed.

The database and cache default to `%USERPROFILE%\\.olaf`. The `microphone` command is not available on Windows.

Now you should be able to call `ffmpeg -v` on the `CMD` command line.

## Installing Olaf
