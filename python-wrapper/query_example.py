#make sure it can find olaf_cffi module
import sys
sys.path.insert(0, '.')

from olaf import Olaf, OlafCommand
from olaf_cffi import ffi, lib
import numpy as np
import librosa
import librosa.display
import matplotlib.pyplot as plt

#Initialize the OLAF objects
config = lib.olaf_config_default()

#store the first ten seconds of the example file
audio_file = librosa.ex('choice')
Olaf(OlafCommand.STORE,audio_file).do(duration=10.0)
original, sr = librosa.load(audio_file,mono=True, sr=config.audioSampleRate,duration=10)

print(sr)

y, sr = librosa.load(audio_file,mono=True, sr=config.audioSampleRate,duration=10,offset=5.0)
y = y * 0.8 #change the volume

y_long = np.concatenate((np.zeros(5*sr),y))

Olaf(OlafCommand.QUERY,audio_file).do(y=y)

fig, ax = plt.subplots(nrows=2, sharex=True, sharey=True)
librosa.display.waveplot(original, sr=sr, ax=ax[0])
ax[0].set(title='Original')
ax[0].label_outer()

librosa.display.waveplot(y_long, sr=sr, ax=ax[1])
ax[1].set(title='Modified')
plt.show()
