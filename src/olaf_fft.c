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
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <assert.h>

#include "pffft.h"

#include "olaf_config.h"
#include "olaf_window.h"
#include "olaf_fft.h"

struct Olaf_FFT{
	//the olaf configuration
	Olaf_Config * config;

	// the fft state info
	PFFFT_Setup *fftSetup;
	float *fft_in;
	float *fft_out;
};


Olaf_FFT * olaf_fft_new(Olaf_Config * config){
	Olaf_FFT *olaf_fft = (Olaf_FFT *) malloc(sizeof(Olaf_FFT));

	//store the config
	olaf_fft->config = config;

	//The raw format and size of float should be 32 bits
	assert(config->bytesPerAudioSample == sizeof(float));

	//the samples should be a 32bit float
	int bytesPerAudioBlock = config->audioBlockSize * config->bytesPerAudioSample;
	//initialize the pfft object
	// We will use a size of audioblocksize 
	// We are only interested in real part
	olaf_fft->fftSetup = pffft_new_setup(config->audioBlockSize,PFFFT_REAL);

	olaf_fft->fft_in = (float *) pffft_aligned_malloc(bytesPerAudioBlock);//fft input
	olaf_fft->fft_out= (float *) pffft_aligned_malloc(bytesPerAudioBlock);//fft output

	return olaf_fft;
}

void olaf_fft_destroy(Olaf_FFT * olaf_fft){
	//cleanup fft structures
	pffft_aligned_free(olaf_fft->fft_in);
	pffft_aligned_free(olaf_fft->fft_out);	
	pffft_destroy_setup(olaf_fft->fftSetup);

	free(olaf_fft);
}


void olaf_fft_forward(Olaf_FFT * olaf_fft,float * audio_data){

	const float* window = hamming_window_1024;

	for(int j = 0 ; j <  olaf_fft->config->audioBlockSize ; j++){
		olaf_fft->fft_in[j] = audio_data[j] * window[j];
	}

	//do the transform
	pffft_transform_ordered(olaf_fft->fftSetup, olaf_fft->fft_in, olaf_fft->fft_out, NULL, PFFFT_FORWARD);

	//copy output to input
	for(int j = 0 ; j <  olaf_fft->config->audioBlockSize ; j++){
		audio_data[j] = olaf_fft->fft_out[j];
	}
}
