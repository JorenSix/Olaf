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
#include <stdlib.h>
#include <stdio.h>
#include <math.h>
#include <assert.h>

#include "olaf_ep_extractor.h"
#include "olaf_config.h"
#include "olaf_max_filter.h"

//state information
struct Olaf_EP_Extractor{
	//the olaf configuration
	Olaf_Config * config;

	// The magnitudes calculated from the fft
	float** mags;

	// The 'vertical' max-filtered magnitudes for the  
	float** maxes;

	int filterIndex;
	
	int audioBlockIndex;

	struct eventpoint * currentEventPoints;

	struct extracted_event_points eventPoints;
};

Olaf_EP_Extractor * olaf_ep_extractor_new(Olaf_Config * config){

	Olaf_EP_Extractor *ep_extractor = (Olaf_EP_Extractor *) malloc(sizeof(Olaf_EP_Extractor));

	ep_extractor->config = config;

	int halfAudioBlockSize = config->audioBlockSize / 2;

	ep_extractor->eventPoints.eventPoints = (struct eventpoint *) calloc(config->maxEventPoints , sizeof(struct eventpoint));
	ep_extractor->eventPoints.eventPointIndex = 0;
	if(ep_extractor->eventPoints.eventPoints == NULL) fprintf(stdout,"Failed to allocate memory: eventPoints");

	//initialize t with a high number
	for(int i = 0 ; i < config->maxEventPoints; i++){
		ep_extractor->eventPoints.eventPoints[i].timeIndex = 1<<23;
	}
	
	ep_extractor->mags  =(float **) calloc(config->filterSizeTime , sizeof(float *));
	if(ep_extractor->mags == NULL) fprintf(stdout,"Failed to allocate memory: mags");
	ep_extractor->maxes = (float **) calloc(config->filterSizeTime , sizeof(float *));
	if(ep_extractor->maxes == NULL) fprintf(stdout,"Failed to allocate memory: maxes");

	for(int i = 0; i < config->filterSizeTime ;i++){
		ep_extractor->maxes[i]= (float *) calloc(halfAudioBlockSize , sizeof(float));
		if(ep_extractor->maxes[i] == NULL) fprintf(stdout,"Failed to allocate memory: maxes[i]");

		ep_extractor->mags[i] = (float *) calloc(halfAudioBlockSize , sizeof(float));
		if(ep_extractor->mags[i] == NULL) fprintf(stderr,"Failed to allocate memory: mags[i]");
	}

	ep_extractor->filterIndex = 0;
	return ep_extractor;
}

void olaf_ep_extractor_destroy(Olaf_EP_Extractor * ep_extractor){
	free(ep_extractor->eventPoints.eventPoints);

	for(int i = 0; i < ep_extractor->config->filterSizeTime ;i++){
	  free(ep_extractor->maxes[i]);
	  free(ep_extractor->mags[i]);
	}

	free(ep_extractor->maxes);
	free(ep_extractor->mags);
	free(ep_extractor);
}


#if defined(__ARM_NEON)

	#include <arm_neon.h>
	
	// ARM NEON implementation here
	float olaf_ep_extractor_max_filter_time(float* array, size_t array_size){
		assert(array_size % 4 == 0);
		float32x4_t vec_max = vld1q_f32(array);
		for (size_t j = 4; j < array_size; j += 4) {
			float32x4_t vec = vld1q_f32(array + j);
			vec_max = vmaxq_f32(vec_max, vec);
		}
		float32x2_t max_val = vpmax_f32(vget_low_f32(vec_max), vget_high_f32(vec_max));
		max_val = vpmax_f32(max_val, max_val);
		return vget_lane_f32(max_val, 0);
	}

#else
	//naive fallback here, sse version is slower!
	float olaf_ep_extractor_max_filter_time(float* array,size_t array_size){
		float max = -10000000;
		for(size_t i = 0 ; i < array_size;i++){
			if(array[i]>max) max = array[i];
		}
		return max;
	}
#endif


void olaf_ep_extractor_print_ep(struct eventpoint e){
	fprintf(stderr,"t:%d, f:%d, u:%d, mag:%.4f\n",e.timeIndex,e.frequencyBin,e.usages,e.magnitude);
}

void olaf_ep_extractor_max_filter_frequency(float* data, float * max, int length,int half_filter_size ){
	size_t filterSize = half_filter_size + half_filter_size + 1;
	olaf_max_filter(data,length,filterSize , max);
}

void extract_internal(Olaf_EP_Extractor * ep_extractor){

	size_t filterSizeTime = (size_t) ep_extractor->config->filterSizeTime;
	size_t halfFilterSizeTime = ep_extractor->config->halfFilterSizeTime;
	size_t halfAudioBlockSize = ep_extractor->config->audioBlockSize/2;
	struct eventpoint * eventPoints = ep_extractor->eventPoints.eventPoints;
	int eventPointIndex = ep_extractor->eventPoints.eventPointIndex;
	int minFreqencyBin = ep_extractor->config->minFrequencyBin;

	//do not start at zero 
	for(size_t j = minFreqencyBin ; j < halfAudioBlockSize - 1 ; j++){

		float currentVal = ep_extractor->mags[halfFilterSizeTime][j];
    //the vertically filtered max value
    float maxVal = ep_extractor->maxes[halfFilterSizeTime][j];

    //if the current value is too low (below abs threshold) or not equal to the
    //vertical max value, then this is not an event point and can be skipped.
    //This also skips calculating the horizontal max value and wasting resources
    if(currentVal < ep_extractor->config->minEventPointMagnitude || currentVal != maxVal){
      continue;
    }

    //Only now execute the horizontal max filter
    float timeslice[filterSizeTime];
    for(size_t t = 0 ; t < filterSizeTime; t++){
      timeslice[t] = ep_extractor->maxes[t][j];
      maxVal = olaf_ep_extractor_max_filter_time(timeslice,ep_extractor->config->filterSizeTime);
    }
		
		if(currentVal == maxVal){
			int timeIndex = ep_extractor->audioBlockIndex - halfFilterSizeTime;
			int frequencyBin = j;
			float magnitude = ep_extractor->mags[halfFilterSizeTime][frequencyBin];

			if(eventPointIndex == ep_extractor->config->maxEventPoints ){
				fprintf(stderr,"Warning: Eventpoint maximum index %d reached, event points are ignored, consider increasing config->maxEventPoints if you see this often. \n",ep_extractor->config->maxEventPoints);
			}else{
				eventPoints[eventPointIndex].timeIndex = timeIndex;
				eventPoints[eventPointIndex].frequencyBin = frequencyBin;
				eventPoints[eventPointIndex].magnitude = magnitude;
				eventPoints[eventPointIndex].usages = 0;

				//fprintf(stderr,"New EP found ");
				//olaf_ep_extractor_print_ep(eventPoints[eventPointIndex]);
				
				eventPointIndex++;
			}
			assert(eventPointIndex <= ep_extractor->config->maxEventPoints);
			
		}
	}
	
	// do not forget to set the event point index for the next run
	ep_extractor->eventPoints.eventPointIndex = eventPointIndex;
}

void rotate(Olaf_EP_Extractor * ep_extractor){
	//shift the magnitudes to the right
	//temporarily keep a reference to the first buffer
	float* tempMax = ep_extractor->maxes[0];
	float* tempMag = ep_extractor->mags[0];

	//shift buffers by one
	for(int i = 1 ; i < ep_extractor->config->filterSizeTime ; i++){
		ep_extractor->maxes[i-1]=ep_extractor->maxes[i];
		ep_extractor->mags[i-1]=ep_extractor->mags[i];
	}
	
	//
	assert(ep_extractor->filterIndex == ep_extractor->config->filterSizeTime-1);

	//store the first at the last place
	ep_extractor->maxes[ep_extractor->config->filterSizeTime-1] = tempMax;
	ep_extractor->mags[ep_extractor->config->filterSizeTime-1] = tempMag;
}

float * olaf_ep_extractor_mags(Olaf_EP_Extractor * olaf_ep_extractor){
	//this needs to be called after rotate() above 
	//and the index is incremented
	if(olaf_ep_extractor->filterIndex==olaf_ep_extractor->config->filterSizeTime-1){
		return olaf_ep_extractor->mags[olaf_ep_extractor->config->filterSizeTime-2];
	}else{
		return olaf_ep_extractor->mags[olaf_ep_extractor->filterIndex-1];
	}
}

struct extracted_event_points * olaf_ep_extractor_extract(Olaf_EP_Extractor * ep_extractor, float* fft_out, int audioBlockIndex){

	int filterIndex = ep_extractor->filterIndex;

	ep_extractor->audioBlockIndex = audioBlockIndex;

	int magnitudeIndex = 0;
	for(int j = 0 ; j < ep_extractor->config->audioBlockSize ; j+=2){
		if(ep_extractor->config->sqrtMagnitude){
			ep_extractor->mags[filterIndex][magnitudeIndex] = sqrt(fft_out[j] * fft_out[j] + fft_out[j+1] * fft_out[j+1]);
		}else{
			ep_extractor->mags[filterIndex][magnitudeIndex] = fft_out[j] * fft_out[j] + fft_out[j+1] * fft_out[j+1];	
		}
		magnitudeIndex++;
	}

	//process the fft frame in frequency (vertically)
	olaf_ep_extractor_max_filter_frequency(ep_extractor->mags[filterIndex],ep_extractor->maxes[filterIndex],ep_extractor->config->audioBlockSize/2,ep_extractor->config->halfFilterSizeFrequency);
	
	if(filterIndex==ep_extractor->config->filterSizeTime-1){
		//enough history to extract event points
		extract_internal(ep_extractor);

		//shift the magnitudes so that there is room for a new audio block 
		rotate(ep_extractor);
	}else{
		//not enough history to extract event points
		ep_extractor->filterIndex++;
	}

	//fprintf(stderr,"Extract event_points for audio block %d \n", audioBlockIndex );
	return &ep_extractor->eventPoints;
}
