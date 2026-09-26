// Olaf: Overly Lightweight Acoustic Fingerprinting
// Copyright (C) 2019-2025  Joren Six

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
#include <stdint.h>
#include <stdbool.h>
#include <assert.h>
#include <math.h>

#include "pffft.h"

#include "olaf_window.h"
#include "olaf_config.h"
#include "olaf_ep_extractor.h"
#include "olaf_fp_extractor.h"
#include "olaf_fp_matcher.h"

/** @struct Olaf_State
 * @brief Holds the complete processing state for the WASM-based Olaf instance.
 */
struct Olaf_State{
	float * audio; /**< Buffer for incoming audio samples */

	size_t audio_block_index; /**< Index of the current audio block */

	size_t audio_sample_index; /**< Index of the current audio sample within the block */

	PFFFT_Setup *fftSetup; /**< FFT configuration and twiddle factors */
	float *fft_in; /**< FFT input buffer */
	float *fft_out; /**< FFT output buffer */

	Olaf_Config *config; /**< Reference to the Olaf configuration */
	Olaf_DB* db; /**< Reference to the fingerprint database */
	Olaf_EP_Extractor *ep_extractor; /**< Event point extractor instance */
	Olaf_FP_Extractor *fp_extractor; /**< Fingerprint extractor instance */
	Olaf_FP_Matcher *fp_matcher; /**< Fingerprint matcher instance */

	struct extracted_event_points * eventPoints; /**< Pointer to the current extracted event points */
	struct extracted_fingerprints * fingerprints; /**< Pointer to the current extracted fingerprints */
};

//the static keyword ensures that
//state is maintained between subsequent
//calls
static struct Olaf_State state;

/**
 * Match results are reported to JavaScript: this function is imported from
 * the "env" module of the wasm instance (see wasm/js/olaf_processor.js).
 */
__attribute__((import_module("env"), import_name("olaf_fp_matcher_callback")))
void olaf_fp_matcher_callback(int matchCount, float queryStart, float queryStop, const char* path, uint32_t matchIdentifier, float referenceStart, float referenceStop);

/** Visualisation: the fft magnitudes of each audio block (only when visualize is set). */
__attribute__((import_module("env"), import_name("olaf_spectrum_callback")))
void olaf_spectrum_callback(int blockIndex, const float* magnitudes, int bins);

/** Visualisation: each new event point (only when visualize is set). */
__attribute__((import_module("env"), import_name("olaf_event_point_callback")))
void olaf_event_point_callback(int timeIndex, int frequencyBin, float magnitude);

static bool visualize = false;

static void olaf_wasm_init(void){
	state.config = olaf_config_esp_32();

	state.fftSetup = pffft_new_setup(state.config->audioBlockSize,PFFFT_REAL);
	state.fft_in = (float*) pffft_aligned_malloc(state.config->audioBlockSize*4);//fft input
	state.fft_out= (float*) pffft_aligned_malloc(state.config->audioBlockSize*4);//fft output

	state.audio = calloc(sizeof(float),state.config->audioBlockSize);
	state.db = olaf_db_new(NULL,true);
	state.ep_extractor = olaf_ep_extractor_new(state.config);
	state.fp_extractor = olaf_fp_extractor_new(state.config);
	state.fp_matcher = olaf_fp_matcher_new(state.config,state.db,olaf_fp_matcher_callback);

	state.audio_sample_index = state.config->audioBlockSize - state.config->audioStepSize;
	state.audio_block_index = 0;
}

/**
 * Enables (1) or disables (0) the visualisation callbacks.
 */
__attribute__((export_name("olaf_wasm_set_visualize")))
void olaf_wasm_set_visualize(int on){
	visualize = on != 0;
}

/**
 * Describes the time-frequency grid of the spectra and event points: writes
 * the sample rate, audio block size, audio step size and the event point
 * latency (in audio blocks) to out.
 */
__attribute__((export_name("olaf_wasm_describe")))
void olaf_wasm_describe(int * out){
	if(state.config == NULL){
		olaf_wasm_init();
	}
	out[0] = state.config->audioSampleRate;
	out[1] = state.config->audioBlockSize;
	out[2] = state.config->audioStepSize;
	//event points are reported this many blocks after their block
	out[3] = state.config->filterSizeTime - 1 - state.config->halfFilterSizeTime;
}

/**
 * Feeds mono 16kHz audio samples to Olaf. Matches are reported via the
 * imported olaf_fp_matcher_callback.
 * @return The index of the current audio block.
 */
__attribute__((export_name("olaf_fingerprint_match")))
int olaf_fingerprint_match(float * audio_buffer, size_t audio_buffer_size){

	if(state.config == NULL){
		olaf_wasm_init();
	}

	//Expect a step size of 128
	size_t step_size = state.config->audioStepSize;
	size_t block_size = state.config->audioBlockSize;
	size_t overlap_size = block_size - step_size;

	const float* window = olaf_fft_window(state.config->audioBlockSize);

	//add the new samples
	for(size_t i = 0 ; i < audio_buffer_size;i++){
		state.audio[state.audio_sample_index] = audio_buffer[i];
		state.audio_sample_index++;

		if(state.audio_sample_index == block_size){
			//block is full, process the full audio block

			//Store in the fft in array while applying the window
			for(size_t j = 0 ; j < block_size ; j++){
				state.fft_in[j] = state.audio[j] * window[j];
			}

			//do the transform
			pffft_transform_ordered(state.fftSetup, state.fft_in, state.fft_out, 0, PFFFT_FORWARD);

			//extract event points: new event points are appended after the
			//ones kept from the previous block
			int previousEventPointIndex = state.eventPoints == NULL ? 0 : state.eventPoints->eventPointIndex;
			state.eventPoints = olaf_ep_extractor_extract(state.ep_extractor,state.fft_out,state.audio_block_index);

			if(visualize){
				olaf_spectrum_callback(state.audio_block_index, olaf_ep_extractor_mags(state.ep_extractor), block_size/2);

				//The time filter window holds the last filterSizeTime blocks and event points are
				//taken from its index halfFilterSizeTime, but labelled audioBlockIndex - halfFilterSizeTime:
				//for an even filterSizeTime that label is one block early. Report the block the
				//event point comes from. The core (and thus fingerprints and matches) keeps the label.
				int time_correction = 2 * state.config->halfFilterSizeTime + 1 - state.config->filterSizeTime;
				for(int j = previousEventPointIndex ; j < state.eventPoints->eventPointIndex ; j++){
					struct eventpoint ep = state.eventPoints->eventPoints[j];
					olaf_event_point_callback(ep.timeIndex + time_correction, ep.frequencyBin, ep.magnitude);
				}
			}

			//if there are enough event points
			if(state.eventPoints->eventPointIndex > state.config->eventPointThreshold){

				//combine the event points into fingerprints
				state.fingerprints = olaf_fp_extractor_extract(state.fp_extractor,state.eventPoints,state.audio_block_index);

				if(state.fingerprints->fingerprintIndex > 0){
					//results are returned via a callback
					olaf_fp_matcher_match(state.fp_matcher,state.fingerprints);
				}
			}

			//Prepare for the next audio samples
			state.audio_block_index++;

			// make room for the new samples: shift the samples to the beginning
			for(size_t j = 0 ; j < overlap_size;j++){
				state.audio[j] = state.audio[j+step_size];
			}
			//next sample should be at overlap_size index
			state.audio_sample_index = overlap_size;
		}
	}

	return state.audio_block_index;
}
