// Olaf: Overly Lightweight Acoustic Fingerprinting
// Copyright (C) 2019-2020  Joren Six

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.

// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include <emscripten.h>
#include <math.h>

#include "pffft.h"

#include "olaf_window.h"
#include "olaf_config.h"
#include "olaf_ep_extractor.h"
#include "olaf_fp_extractor.h"
#include "olaf_fp_matcher.h"

struct Olaf_State{
	float audio[512];
	int audioBlockIndex;

	PFFFT_Setup *fftSetup;
	float *fft_in;//fft input
	float *fft_out;//fft output

	Olaf_Config *config;
	Olaf_FP_DB* db;
	Olaf_EP_Extractor *ep_extractor;
	Olaf_FP_Extractor *fp_extractor;
	Olaf_FP_Matcher *fp_matcher;

	struct extracted_event_points * eventPoints;
	struct extracted_fingerprints * fingerprints;
};
 

inline int max ( int a, int b ) { return a > b ? a : b; }
inline int min ( int a, int b ) { return a < b ? a : b; }

//the static keyword ensures that
//state is maintained between subsequent
//calls
static struct Olaf_State state;

int EMSCRIPTEN_KEEPALIVE olaf_fingerprint_match(float * audio_buffer, uint32_t * fingerprints ){
	
	if(state.fftSetup == NULL){
		//initialize
		state.fftSetup = pffft_new_setup(512,PFFFT_REAL);
		state.fft_in = (float*) pffft_aligned_malloc(512*4);//fft input
		state.fft_out= (float*) pffft_aligned_malloc(512*4);//fft output

		//Get the default configuration
		state.config = olaf_config_default();
		state.db = olaf_fp_db_new(NULL,true);
		state.ep_extractor = olaf_ep_extractor_new(state.config);
		state.fp_extractor = olaf_fp_extractor_new(state.config);
		state.fp_matcher = olaf_fp_matcher_new(state.config,state.db);

		//cleanup fft structures
		//pffft_aligned_free(fft_in);
		//pffft_aligned_free(fft_out);
		//pffft_destroy_setup(fftSetup);
	}

	//printf("Current audio block index: %d \n",state.audioBlockIndex);

	//make a full audio buffer.
	//The first buffer starts with zeros
	for(size_t i = 0 ; i < 256 ; i++){
		//shift the old samples to the beginning
		state.audio[i]=state.audio[i+256];
		//add the new samples to the end
		state.audio[i+256]=audio_buffer[i];
	}

	//gaussian windowing
	for(size_t i = 0 ; i <  512 ; i++){
		state.fft_in[i] = state.audio[i] * gaussian_window[i];
	}

	//do the transform
	pffft_transform_ordered(state.fftSetup, state.fft_in, state.fft_out, 0, PFFFT_FORWARD);

	//extract event points
	state.eventPoints  =  olaf_ep_extractor_extract(state.ep_extractor,state.fft_out,state.audioBlockIndex);

	//printf("Event point index: %d \n",state.eventPoints->eventPointIndex);

	//if there are enough event points
	if(state.eventPoints->eventPointIndex > state.config->eventPointThreshold){

		//combine the event points into fingerprints
		state.fingerprints = olaf_fp_extractor_extract(state.fp_extractor,state.eventPoints,state.audioBlockIndex);

		size_t fingerprintIndex = state.fingerprints->fingerprintIndex;
		//printf("FP index: %zu \n",fingerprintIndex);

		if(fingerprintIndex > 0){
			for(size_t i = 0; i < 256 && i < fingerprintIndex; i++){
				size_t index = i * 6;
				fingerprints[index] = state.fingerprints->fingerprints[i].timeIndex1;
				fingerprints[index+1] = state.fingerprints->fingerprints[i].frequencyBin1;
				fingerprints[index+2] = state.fingerprints->fingerprints[i].timeIndex2;
				fingerprints[index+3] = state.fingerprints->fingerprints[i].frequencyBin2;
				fingerprints[index+4] = olaf_fp_extractor_hash(state.fingerprints->fingerprints[i]);
				fingerprints[index+5] = olaf_fp_db_find_single(state.db,fingerprints[index+4],0) ? 1 : 0;

				//printf("t1: %d, f1: %d t2: %d f2:%d \n",fingerprints[index],fingerprints[index+1],fingerprints[index+2],fingerprints[index+3]);
			}

			int maxMatchScore = olaf_fp_matcher_match(state.fp_matcher,state.fingerprints);

			printf("Max Match score: %d \n",maxMatchScore);

			for(size_t i = 0; i < 256 && i < fingerprintIndex; i++){
				size_t index = i * 6;
				fingerprints[index+5] = maxMatchScore >= state.config->minMatchCount ? maxMatchScore : 0;
			}
		}
		
	}

	//store the magnitudes in place of the audio buffer
	float * mags = audio_buffer;
	int magnitudeIndex = 0;
	for(size_t i = 0 ; i < 512 ; i+=2){
		mags[magnitudeIndex] = state.fft_out[i] * state.fft_out[i] + state.fft_out[i+1] * state.fft_out[i+1];
		magnitudeIndex++;
	}

	state.audioBlockIndex++;

	return state.audioBlockIndex;
}

float EMSCRIPTEN_KEEPALIVE olaf_fft_frequency_estimate(float * audio_buffer, size_t length){
	if(state.fftSetup == NULL){
		//initialize
		state.fftSetup = pffft_new_setup(512,PFFFT_REAL);
		state.fft_in = (float*) pffft_aligned_malloc(512*4);//fft input
		state.fft_out= (float*) pffft_aligned_malloc(512*4);//fft output

		//cleanup fft structures
		//pffft_aligned_free(fft_in);
		//pffft_aligned_free(fft_out);
		//pffft_destroy_setup(fftSetup);
	}



	//printf("Current audio block index: %zu \n",state.audioBlockIndex);

	//make a full audio buffer.
	//The first buffer starts with zeros
	for(size_t i = 0 ; i < length ; i++){
		//shift the old samples to the beginning
		state.audio[i]=state.audio[i+256];
		//add the new samples to the end
		state.audio[i+256]=audio_buffer[i];
	}

	//gaussian windowing
	for(size_t i = 0 ; i <  512 ; i++){
		state.fft_in[i] = state.audio[i] * gaussian_window[i];
	}

	
	

	//do the transform
	pffft_transform_ordered(state.fftSetup, state.fft_in, state.fft_out, 0, PFFFT_FORWARD);

	float * mags = audio_buffer;
	int magnitudeIndex = 0;
	for(size_t i = 0 ; i < 512 ; i+=2){
		mags[magnitudeIndex] = state.fft_out[i] * state.fft_out[i] + state.fft_out[i+1] * state.fft_out[i+1];
		magnitudeIndex++;
	}

	float maxMagnitude=0;
	int maxIndex = 0;
	for(size_t i = 0 ; i < length/2 ; i++){
		if(mags[i] > maxMagnitude){
			maxMagnitude = mags[i];
			maxIndex=i;
		}
	}

	float ym1 = mags[max(0,maxIndex-1)];
	float y0 = maxMagnitude;
	float yp1 = mags[min(255,maxIndex+1)];

	//see Improving FFT Frequency Measurement Resolution by Parabolic and Gaussian Spectrum Interpolation
	float fractionalOffsetGuassian = log(yp1/ym1)/(2*log((y0 * y0) / (yp1 * ym1)));
	float gaussEstimate = 8000.0/512.0 * (maxIndex + fractionalOffsetGuassian);

	state.audioBlockIndex++;

	return gaussEstimate;
}

void cleanup(){
	//cleanup fft structures
	//pffft_aligned_free(state.fft_in);
	//pffft_aligned_free(state.fft_out);
	//pffft_destroy_setup(state.fftSetup);
}

int main(int argc, const char* argv[]){
	(void)(argc);
	(void)(argv);
	printf("Hello world!\n");
	return 0;
}

