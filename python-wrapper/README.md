h1. OLAF -  Overly Lightweight Acoustic Fingerprinting - Python Wrapper

Olaf is a C application or library for content-based audio search. Olaf is able to extract fingerprints from an audio stream, and either store those fingerprints in a database, or find a match between extracted fingerprints and stored fingerprints. This page explains how to use Olaf's functionality from Python.


The full set of commands to download Olaf, make sure the @~/.olaf@ directory exists, build the library and Python cffi wrapper and finally use the wrapper looks as follows:

<pre>
# clone the repository  
git clone --depth 1 https://github.com/JorenSix/Olaf
cd Olaf
# To automatically setup folders for Olaf files
make
make install
#Build the library version of Olaf libolaf.so
make clean
make lib
# Install the python requirements, librosa and numpy are 
# not strictly necessary but very practical
pip install -r python-wrapper/requirements.txt
# Build the CFFI python library
python python-wrapper/setup.py
# Makes sure that libolaf.so can be found 
export LD_LIBRARY_PATH=`pwd`/bin
# Test the python wrapper
python python-wrapper/spectrogram_example.py
</pre>

This should result in a graph similar to the one below:

!../docs/olaf-power-spectrum.webp(Olaf Spectrum and event points)!

h1. Using the Python Wrapper

The "@olaf.py@":olaf.py file provides the a high level Python API with the most basic functionality exposed. The object expects a command and either a filename or a numpy array with audio samples. If a numpy array is provided, it is expected to contain mono audio in the correct sample rate.

The high level Python API exposes the following commands:

# @STORE@ or index an audio file. Fingerprints are extracted and stored in a key value store.
# @QUERY@ the index for matches, results are returned in a dictionary struct with self-explanitory names.
# @EXTRACT_EVENT_POINTS@ Simply extracts the 'event points'. Essentially peak picking in the spectral domain. It returns a list with time,frequency pairs. Time expressed in steps and frequeny in FFT bins.
# @EXTRACT_FINGERPRINTS@ extracts the 'fingerprints'. These are a combination of two or three event points with a hash. Again time is expressed in steps and frequeny in FFT bins.
# @EXTRACT_MAGNITUDES@ returns the full magnitude spectrum as calculated by Olaf. This is mainly for debugging and visualization purposes. It should be similar to other STFT implementations with similar time and frequency resolution.

The high level API is called as follows:

<pre>
from olaf import Olaf, OlafCommand
from olaf_cffi import ffi, lib
import librosa

audio_file = librosa.ex('choice')
Olaf(OlafCommand.STORE,audio_file).do(duration=10.0)

y, sr = librosa.load(audio_file,mono=True, sr=16000,duration=10,offset=7.0)
y = y * 0.8 #change the volume

results = Olaf(OlafCommand.QUERY,audio_file).do(y=y)
print(results)
</pre>
