# ESP32 Olaf - Overly Lightweight Acoustic Fingerprinting on the ESP32

Olaf is designed with embedded devices in mind. It has a low memory use and computational requirements which are compatible with e.g. the ESP32 line of microcontrollers devices. Some compatible devices include the [SparkFun ESP32 Thing](https://www.sparkfun.com/products/13907), the [ESP32 based M5 stick C](https://shop.m5stack.com/products/stick-c) or [Arduino Nano RP2040 Connect](https://docs.arduino.cc/hardware/nano-rp2040-connect).

Olaf also needs access to streaming audio. This can be audio read from an SD-card but, more likely, audio from a microphone. Digital microphones have some great features: a low-noise floor, great at picking up omnidirectional sound and inexpensive. Unfortunately they are a pain to setup correctly. Typically they use an [I2S](https://dronebotworkshop.com/esp32-i2s/) bus and if either the microphone datasheet or the platform you use is not well documented the exact parameters for the I2S bus are sometimes unclear and difficult to find and to debug.

A readily available and easy to use MEMS microphone is the INMP441 MEMS Microphone. This tutorial show [how to use the INMP441 microphone with an ESP32](https://dronebotworkshop.com/esp32-i2s/). This microphone is also used by the Olaf ESP32 examples. There are two examples.

## ESP32 INMP441 WiFi Microphone

This small program sends audio from the microphone over WiFi to a computer to listen to the microphone. This is to make sure that the microphone works as expected and the audio samples are correctly interpreted. It validates the I2S settings like buffer sizes, sample rates, audio formats, stereo or mono settings, ...

Note that the SSID, password and receiving computer IP-address need to be configured.

To listen to the incoming audio an UDP port needs to be read and send to a program that can interpret and play or store audio. With [netcat](https://en.wikipedia.org/wiki/Netcat) UDP data can be captured. With [ffmpeg and ffplay](https://ffmpeg.org) audio can be payed or stored. In practice the receiving computer might run this to hear the microphone:

```bash
#for playback
nc -l -u 3000 | ffplay -f f32le -ar 16000 -ac 1  -

#for capturing the audio
nc -l -u 3000 | ffmpeg -f f32le -ar 16000 -ac 1 -i pipe: microphone.wav
```

## ESP32 INMP441 Olaf

This code shows how to match incoming audio from a INMP441 microphone to fingerprints stored in a header file. The embedded version of Olaf does not use a key value store but a list of hashes stored in a `src/olaf_fp_ref_mem.h` header file. This header file is the fingerprint index.

The 'index' or header file can be created on a computer to contain fingerprints extracted from audio. By default it recognizes 'Let It Go' from the Frozen soundtrack. The program reads audio samples and operates on overlapping blocks of audio. The code in `loop()` makes sure that a full block is read and handed over to Olaf for recognition.

Once audio is recognized a callback is ... called. The `olaf_fp_matcher_callback_esp32` callback starts blinking a led during recognition. The ESP32 stops blinking once recognition ends.

To match another audio file, a header file with fingerprints extracted from that audio file needs to be created. This is done as follows:

```bash
git clone --depth 1 https://github.com/JorenSix/Olaf
cd Olaf
#first install the 'regular' Olaf for 'to_raw' support
make && make install
make clean
#Create the 'in memory' version
make mem
#Convert your audio
olaf to_raw your_audio_file.mp3
#extract the fingerprints and write the header file
bin/olaf_mem store olaf_audio_your_audio_file.raw "arandomidentifier" > src/olaf_fp_ref_mem.h
```

By default the `src/olaf_fp_ref_mem.h` is included in the ESP32 code. To test and debug this header file, query the `mem` version of Olaf on your computer: `bin/olaf query olaf_audio_your_audio_file.raw "arandomidentifier"`. The ESP32 version is basically the same as the `mem` version, only the audio comes from a MEMS microphone input in the ESP32 version and not from a file.

Once your are sure that the `mem` version of Olaf works as expected and the INMP441 microphone is tested, the ESP32 version can be deployed on the ESP32 hardware using the Arduino IDE.