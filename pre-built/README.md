# OLAF on Windows

Getting the command line olaf application to work on Windows requires a few steps.

## Installing dependencies: ffmpeg and Ruby

Both Ruby and ffmpeg need to be installed on your system and both need to be **available on your path**.

For ffmpeg you need to copy `ffmpeg.exe` to e.g. `c:\windows\system32` or another location on your `$PATH`. You can find [recent ffmpeg builds for Windows here](https://github.com/BtbN/FFmpeg-Builds/releases) or [here](https://www.gyan.dev/ffmpeg/builds/). Download, unzip and copy the exe. Only `ffmpeg.exe` is needed.

The easy way to install Ruby on Windows is to use the [Ruby Installer](https://rubyinstaller.org/). Simply install a Ruby environment. Olaf does not need a specific Ruby version: anything Ruby environment above 2.5 will work.

Now you should be able to call `ruby -v` and `ffmpeg -v` on the `CMD` command line.

## Installing Olaf

Download [`olaf_c.exe` here](https://github.com/JorenSix/Olaf/tree/master/pre-built) and copy it to a fixed location. For example `'C:/Program Files/olaf_c.exe'`

Download [olaf.rb](https://github.com/JorenSix/Olaf/blob/master/olaf.rb), open it in a text editor and modify the "EXECUTABLE_LOCATION" to e.g. `'C:/Program Files/olaf_c.exe'`.

Now you can call Olaf as follows, in the directory where olaf.rb is also found:

```bash
ruby olaf.rb store test.mp3
ruby olaf.rb query test.mp3
```