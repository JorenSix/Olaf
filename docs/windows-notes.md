# OLAF on Windows

Getting the command line olaf application to work on Windows requires a few steps.

## Installing dependencies: ffmpeg and Ruby

ffmpeg needs to be installed on your system and **available on your path**.

For ffmpeg you need to copy `ffmpeg.exe` to e.g. `c:\windows\system32` or another location on your `$PATH`. You can find [recent ffmpeg builds for Windows here](https://github.com/BtbN/FFmpeg-Builds/releases) or [here](https://www.gyan.dev/ffmpeg/builds/). Download, unzip and copy the exe. Only `ffmpeg.exe` is needed.

Now you should be able to call `ffmpeg -v` on the `CMD` command line.

## Installing Olaf
