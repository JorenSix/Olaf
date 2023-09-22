#make sure it can find olaf_cffi module
import sys
sys.path.insert(0, '.')

import librosa
from olaf_cffi import ffi, lib
from enum import Enum
import numpy as np

class OlafCommand(Enum):
    STORE = 1
    QUERY = 2
    EXTRACT_EVENT_POINTS = 3
    EXTRACT_FINGERPRINTS = 4
    EXTRACT_MAGNITUDES = 5

@ffi.def_extern()
def olaf_python_wrapper_handle_result( matchCount,  queryStart,  queryStop, path,  matchIdentifier,  referenceStart,  referenceStop):
	if(matchCount != 0):
		d = {
			'matchCount':matchCount,
			'queryStart':queryStart,
			'queryStop':queryStop,
			'path':ffi.string(path),
			'matchIdentifier':matchIdentifier,
			'referenceStart':referenceStart,
			'referenceStop':referenceStop
		}
		Olaf.results.append(d)

	return None

class Olaf:
	results = []

	# Initializing
	def __init__(self,command,path):
		#Initialize the OLAF objects
		self.path = path
		self.command = command
		self.audio_identifier = lib.olaf_db_string_hash(ffi.new("char []", str.encode(self.path)),len(path));
		self.config = lib.olaf_config_default()
		self.fft = lib.olaf_fft_new(self.config)
		self.ep_extractor = lib.olaf_ep_extractor_new(self.config)
		self.fp_extractor = lib.olaf_fp_extractor_new(self.config)

		if self.command == OlafCommand.EXTRACT_MAGNITUDES:
			#Forces olaf to calculate the sqrt of the magnitudes, 
			#for visualization
			self.config.sqrtMagnitude = True
		if self.command == OlafCommand.QUERY:
			self.fp_db = lib.olaf_db_new(self.config.dbFolder,True);
			Olaf.results.clear
			#register callback
			self.fp_matcher = lib.olaf_fp_matcher_new(self.config,self.fp_db,lib.olaf_python_wrapper_handle_result)
		if self.command == OlafCommand.STORE:
			self.fp_db = lib.olaf_db_new(self.config.dbFolder,False);
			self.fp_db_writer = lib.olaf_fp_db_writer_new(self.fp_db,self.audio_identifier)

		print("Initialized OLAF with default config")
		print("\tAudio sample rate:\t" + str(self.config.audioSampleRate))
		print("\tDatabase location:\t" + str(ffi.string(self.config.dbFolder)))
		print("\tAudio identifier:\t" + str(self.audio_identifier))
		print("\tAudio path:\t" + str(self.path))
			
	# Destructor frees resources
	def __del__(self):
		lib.olaf_ep_extractor_destroy(self.ep_extractor)
		lib.olaf_fp_extractor_destroy(self.fp_extractor)
		if self.command == OlafCommand.QUERY:
			lib.olaf_fp_matcher_destroy(self.fp_matcher)
			lib.olaf_db_destroy(self.fp_db)

		if self.command == OlafCommand.STORE:
			lib.olaf_fp_db_writer_destroy(self.fp_db_writer,True)
			lib.olaf_db_destroy(self.fp_db)

		lib.olaf_fft_destroy(self.fft)
		lib.olaf_config_destroy(self.config)
		
		print("Cleaned memory and resources")


	def do(self,duration=None,y=None):

		if y is None :
			y, sr = librosa.load(self.path, mono=True, sr=self.config.audioSampleRate,duration=duration)

		blocks = np.lib.stride_tricks.sliding_window_view(y, self.config.audioBlockSize)[::self.config.audioStepSize, :]

		event_points = []
		fingerprints = []
		magnitudes = []
		audio_block_index = 0;
		fps = None
		eps = None

		for block in blocks:
			
			#Copy the block, the FFT modifies the data
			audio_block_copy = np.copy(block)

			#prepare the audio samples to be used by the c library
			fft_samples = ffi.cast("float *", audio_block_copy.ctypes.data)
			
			#Forward FFT transform the audio samples, the result is stored in place!
			lib.olaf_fft_forward(self.fft,fft_samples)

			#Extract the event points
			eps = lib.olaf_ep_extractor_extract(self.ep_extractor,fft_samples,audio_block_index)
			
			if self.command == OlafCommand.EXTRACT_MAGNITUDES:
				#For visualization purposes, copy the magnitudes
				mags = lib.olaf_ep_extractor_mags(self.ep_extractor)
				#Conver to python float, four bytes per float
				mags = np.frombuffer(ffi.buffer(mags, 512*4), dtype=np.float32)
				magnitudes.append(list(mags))

			#Copy the event points and combine them into fingerprints
			if(eps.eventPointIndex > self.config.eventPointThreshold):

				if self.command == OlafCommand.EXTRACT_EVENT_POINTS:
					for i in range(eps.eventPointIndex):
						event_points.append([eps.eventPoints[i].timeIndex,eps.eventPoints[i].frequencyBin])

				#Combine event points into fingerprints
				fps = lib.olaf_fp_extractor_extract(self.fp_extractor,eps,audio_block_index)
				
				if self.command == OlafCommand.STORE:
					lib.olaf_fp_db_writer_store(self.fp_db_writer,fps);

				if self.command == OlafCommand.QUERY:
					lib.olaf_fp_matcher_match(self.fp_matcher,fps);

				
				if self.command == OlafCommand.EXTRACT_FINGERPRINTS:
					for i in range(fps.fingerprintIndex):
						f = fps.fingerprints[i]
						fp_hash = lib.olaf_fp_extractor_hash(f)
						fingerprints.append([
							fp_hash,
							f.timeIndex1,f.frequencyBin1,f.magnitude1,
							f.timeIndex2,f.frequencyBin2,f.magnitude2,
							f.timeIndex3,f.frequencyBin3,f.magnitude3
							])

				#Mark the fingerpint index to zero, important!
				fps.fingerprintIndex=0

			#Increase the audio block counter
			audio_block_index = audio_block_index + 1

		#Extract last fingerprints from remaining event points
		fps = lib.olaf_fp_extractor_extract(self.fp_extractor,eps,audio_block_index);
		
		#return the requested info based on command:
		if self.command == OlafCommand.STORE:
			lib.olaf_fp_db_writer_store(self.fp_db_writer,fps);

			#also store meta-data for the file
			meta_data = ffi.new("Olaf_Resource_Meta_data *")
			meta_data.duration = audio_block_index / self.config.audioSampleRate * self.config.audioBlockSize;

			meta_data.path = ffi.new("char [512]", str.encode(self.path))
			meta_data.fingerprints = lib.olaf_fp_extractor_total(self.fp_extractor);

			#A bit of cluncky syntax to get a uint32_t * type
			audio_id = ffi.new("uint32_t [1]",[self.audio_identifier])
			audio_id_pointer = ffi.addressof(audio_id,0)
			meta_data.path = ffi.new("char [512]", str.encode(self.path))

			lib.olaf_db_store_meta_data(self.fp_db,audio_id_pointer,meta_data);

			return True
		if self.command == OlafCommand.QUERY:
			lib.olaf_fp_matcher_match(self.fp_matcher,fps);
			#lib.olaf_fp_matcher_callback_print_header();
			lib.olaf_fp_matcher_print_results(self.fp_matcher);
			if len(Olaf.results) == 0 :
				return None
			return Olaf.results
			
		if self.command == OlafCommand.EXTRACT_EVENT_POINTS:
			return event_points
		if self.command == OlafCommand.EXTRACT_MAGNITUDES:
			return magnitudes
		if self.command == OlafCommand.EXTRACT_FINGERPRINTS:
			for i in range(fps.fingerprintIndex):
				f = fps.fingerprints[i]
				fp_hash = lib.olaf_fp_extractor_hash(f)
				fingerprints.append([
					fp_hash,
					f.timeIndex1,f.frequencyBin1,f.magnitude1,
					f.timeIndex2,f.frequencyBin2,f.magnitude2,
					f.timeIndex3,f.frequencyBin3,f.magnitude3
					])

			return fingerprints


if __name__ == "__main__":

	audio_file = librosa.ex('vibeace')

	olaf = Olaf(OlafCommand.STORE,audio_file)
	olaf.do();
	del olaf

	olaf = Olaf(OlafCommand.QUERY,audio_file)
	olaf.do();
	del olaf

	olaf = Olaf(OlafCommand.EXTRACT_FINGERPRINTS,audio_file)
	olaf.do();
	del olaf

	olaf = Olaf(OlafCommand.EXTRACT_MAGNITUDES,audio_file)
	olaf.do();
	del olaf

	olaf = Olaf(OlafCommand.EXTRACT_EVENT_POINTS,audio_file)
	olaf.do();
	del olaf
