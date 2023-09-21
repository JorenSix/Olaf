from olaf_cffi import ffi, lib
from olaf import Olaf, OlafCommand
import librosa
import librosa.display
import numpy as np
import matplotlib.pyplot as plt

#Initialize the OLAF objects
config = lib.olaf_config_default()

#Load sample audio
audio_file = librosa.ex('vibeace')
#Resample and make sure it is mono audio
y, sr = librosa.load(audio_file, mono=True, sr=config.audioSampleRate, duration=15)

print("Using the default OLAF configuration, audio sample rate:" + str(config.audioSampleRate))
print("Using the librosa example: " + audio_file)

magnitudes  = Olaf(OlafCommand.EXTRACT_MAGNITUDES,audio_file).do()
eventpoints = Olaf(OlafCommand.EXTRACT_EVENT_POINTS,audio_file).do()

fig, ax = plt.subplots(nrows=2, ncols=1)

stft = librosa.stft(y,hop_length=config.audioStepSize, n_fft=config.audioBlockSize, center=False)
D = librosa.amplitude_to_db(np.abs(stft), ref=np.max)
img = librosa.display.specshow(D, sr=config.audioSampleRate, hop_length=config.audioStepSize, x_axis='time', ax=ax[0])
ax[0].set(title='Power spectrogram - Librosa')
ax[0].label_outer()
fig.colorbar(img, ax=ax[0], format="%+2.f dB")

print("Shape of librosa STFT call: " + str(D.shape))
print("Shape of OLAF STFT: " + str(len(magnitudes[0])) + "x" + str(len(magnitudes)) )

olaf_stft = np.zeros([512,len(magnitudes)])
for t in range(len(magnitudes)):
	for f in range(512):
		olaf_stft[f,t] = magnitudes[t][f]

#scatter plot of event points
time_indexes = []
frequency_bins = []
for ep in eventpoints:
	time_indexes.append(ep[0] )
	frequency_bins.append(ep[1])

D = librosa.amplitude_to_db(olaf_stft, ref=np.max)
img = ax[1].pcolormesh(D)
ax[1].set(title='Power spectrogram - OLAF')
ax[1].label_outer()
fig.colorbar(img, ax=ax[1], format="%+2.f dB")
#scatter plot with event points
ax[1].plot(time_indexes,frequency_bins,'rx')


plt.show()