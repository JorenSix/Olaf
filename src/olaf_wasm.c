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
	
	size_t audio_block_index;

	size_t audio_sample_index;

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

void olaf_fp_matcher_callback_js(int matchCount, float queryStart, float queryStop, const char* path, uint32_t matchIdentifier, float referenceStart, float referenceStop) {
  EM_ASM_ARGS({ olaf_fp_matcher_callback($0, $1, $2, $3, $4, $5, $6); }, matchCount, queryStart, queryStop, path, matchIdentifier, referenceStart, referenceStop);
}


int EMSCRIPTEN_KEEPALIVE olaf_fingerprint_match(float * audio_buffer, size_t audio_buffer_size, uint32_t * fingerprints, size_t fingerprints_size ){

	//Expect a step size of 128
	size_t step_size = state.config->audioStepSize;
	size_t block_size = state.config->audioBlockSize;
	size_t overlap_size = block_size - step_size;

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
		state.fp_matcher = olaf_fp_matcher_new(state.config,state.db,olaf_fp_matcher_callback_js);

		state.audio_sample_index = overlap_size;
		state.audio_block_index = 0;
	}

	const float* window = olaf_fft_window(state.config->audioBlockSize);


	

	//add the new samples
	for(size_t i = 0 ; i < audio_buffer_size;i++){
		state.audio[state.audio_sample_index] = audio_buffer[i];
		state.audio_sample_index++;

		if(state.audio_sample_index == (size_t) block_size){
			//block is full, process the full audio block
			
			//Store in the fft in array while applying the window 
			for(int i = 0 ; i <  state.config->audioBlockSize ; i++){
				state.fft_in[i] = state.audio[i] * window[i];
			}

			//do the transform
			pffft_transform_ordered(state.fftSetup, state.fft_in, state.fft_out, 0, PFFFT_FORWARD);

			//extract event points
			state.eventPoints = olaf_ep_extractor_extract(state.ep_extractor,state.fft_out,state.audio_block_index);

			
			//if there are enough event points
			if(state.eventPoints->eventPointIndex > state.config->eventPointThreshold){
				
				//combine the event points into fingerprints
				state.fingerprints = olaf_fp_extractor_extract(state.fp_extractor,state.eventPoints,state.audio_block_index);
				

				if(state.fingerprints->fingerprintIndex > 0){
									
					//resulst are returned via a callback
					olaf_fp_matcher_match(state.fp_matcher,state.fingerprints);
					
				}
			}
			

			//Prepare for the next audio samples
			state.audio_block_index++;
			
			// make room for the new samples: shift the samples to the beginning
			for(size_t i = 0 ; i < overlap_size;i++){
				state.audio[i] = state.audio[i+step_size];
			}
			//next sample should be at overlap_size index
			state.audio_sample_index = overlap_size;
		}
	}

	return state.audio_block_index;
}

void cleanup(){
	//cleanup fft structures
	//pffft_aligned_free(state.fft_in);
	//pffft_aligned_free(state.fft_out);
	//pffft_destroy_setup(state.fftSetup);
	free(state.audio);
}


