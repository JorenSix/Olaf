// Olaf: Overly Lightweight Acoustic Fingerprinting
// Copyright (C) 2019-2023  Joren Six

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
	float * audio;
	int audioBlockIndex;

	PFFFT_Setup *fftSetup;
	float *fft_in;//fft input
	float *fft_out;//fft output

	Olaf_Config *config;
	Olaf_DB* db;
	Olaf_EP_Extractor *ep_extractor;
	Olaf_FP_Extractor *fp_extractor;
	Olaf_FP_Matcher *fp_matcher;

	struct extracted_event_points * eventPoints;
	struct extracted_fingerprints * fingerprints;
};
 

//the static keyword ensures that
//state is maintained between subsequent
//calls
static struct Olaf_State state;

int EMSCRIPTEN_KEEPALIVE olaf_fingerprint_match(float * audio_buffer, uint32_t * fingerprints ){

	(void)(fingerprints);

	if(state.fftSetup == NULL){
		//Get the default configuration
		state.config = olaf_config_esp_32();

		state.fftSetup = pffft_new_setup(state.config->audioBlockSize,PFFFT_REAL);
		state.fft_in = (float*) pffft_aligned_malloc(state.config->audioBlockSize*4);//fft input
		state.fft_out= (float*) pffft_aligned_malloc(state.config->audioBlockSize*4);//fft output

		state.audio = calloc(sizeof(float),state.config->audioBlockSize);
		state.db = olaf_db_new(NULL,true);
		state.ep_extractor = olaf_ep_extractor_new(state.config);
		state.fp_extractor = olaf_fp_extractor_new(state.config);
		state.fp_matcher = olaf_fp_matcher_new(state.config,state.db);

		state.audioBlockIndex = 0;
	}


	//Expect a step size of 128
	size_t step_size = state.config->audioStepSize;
	size_t block_size = state.config->audioBlockSize;
	
	size_t overlap_size = block_size - step_size;
	size_t steps_per_block = block_size / step_size;
	size_t read_index = 0;

	const float* window = olaf_fft_window(state.config->audioBlockSize);
	
	for(size_t j = 0; j < steps_per_block ; j++){

		// make room for the new samples: shift the samples to the beginning
		for(size_t i = 0 ; i < overlap_size;i++){
			state.audio[i] = state.audio[i+step_size];
		}

		//add the new samples
		for(size_t i = 0 ; i < step_size;i++){
			state.audio[overlap_size+i] = audio_buffer[read_index];
			read_index++;
		}

		//Store in the fft in array while applying the window 
		for(int i = 0 ; i <  state.config->audioBlockSize ; i++){
			state.fft_in[i] = state.audio[i] * window[i];
		}
	
		//do the transform
		pffft_transform_ordered(state.fftSetup, state.fft_in, state.fft_out, 0, PFFFT_FORWARD);

		//extract event points
		state.eventPoints = olaf_ep_extractor_extract(state.ep_extractor,state.fft_out,state.audioBlockIndex);

		//printf("Event point index: %d \n",state.eventPoints->eventPointIndex);

		//if there are enough event points
		if(state.eventPoints->eventPointIndex > state.config->eventPointThreshold){
			
			//combine the event points into fingerprints
			state.fingerprints = olaf_fp_extractor_extract(state.fp_extractor,state.eventPoints,state.audioBlockIndex);


			size_t fingerprintIndex = state.fingerprints->fingerprintIndex;
			//printf("FP index: %zu \n",fingerprintIndex);

			if(fingerprintIndex > 0){

				int maxMatchScore = 0;
				
				olaf_fp_matcher_match(state.fp_matcher,state.fingerprints);
				//olaf_fp_matcher_print_header();
				//olaf_fp_matcher_print_results(state.fp_matcher);
				
				//printf("Match called, fp index: %d \n",state.fingerprints->fingerprintIndex);
				//state.fingerprints->fingerprintIndex = 0;
			}
		}
		state.audioBlockIndex++;
	}
	//printf("Audio block index: %d \n",state.audioBlockIndex );
	//assert(read_index == block_size);

	//store the magnitudes in place of the audio buffer
	/*float * mags = audio_buffer;
	int magnitudeIndex = 0;
	for(size_t i = 0 ; i < block_size ; i+=2){
		//mags[magnitudeIndex] = state.fft_out[i] * state.fft_out[i] + state.fft_out[i+1] * state.fft_out[i+1];
		//magnitudeIndex++;
	}*/

	return state.audioBlockIndex;
}

void cleanup(){
	//cleanup fft structures
	//pffft_aligned_free(state.fft_in);
	//pffft_aligned_free(state.fft_out);
	//pffft_destroy_setup(state.fftSetup);
	free(state.audio);
	
}


