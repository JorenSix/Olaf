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
#include <stdlib.h>
#include <stdio.h>
#include <math.h>
#include <assert.h>

#include "olaf_ep_extractor.h"
#include "olaf_config.h"

//state information
struct Olaf_EP_Extractor{
	//the olaf configuration
	Olaf_Config * config;

	// The magnitudes calculated from the fft
	float** mags;

	// The 'vertical' max-filtered magnitudes for the  
	float** maxes;

	// The horizontally max-filtered magnitudes for the
	// current frame
	float* horizontalMaxes;

	int filterIndex;
	
	int audioBlockIndex;

	struct eventpoint * currentEventPoints;

	struct extracted_event_points eventPoints;

	FILE *spectrogram_file;
	FILE *maxes_file;
};

Olaf_EP_Extractor * olaf_ep_extractor_new(Olaf_Config * config){

	Olaf_EP_Extractor *ep_extractor = (Olaf_EP_Extractor*) malloc(sizeof(Olaf_EP_Extractor));

	ep_extractor->config = config;

	int halfAudioBlockSize = config->audioBlockSize / 2;

	ep_extractor->horizontalMaxes = (float*) malloc(halfAudioBlockSize * sizeof(float));

	ep_extractor->eventPoints.eventPoints = (struct eventpoint*) malloc(config->maxEventPoints * sizeof(struct eventpoint));
	ep_extractor->eventPoints.eventPointIndex = 0;
	
	ep_extractor->mags  = (float **) malloc(config->filterSizeTime * sizeof(float *));
	ep_extractor->maxes = (float **) malloc(config->filterSizeTime * sizeof(float *));

	for(int i = 0; i < config->filterSizeTime ;i++){
		ep_extractor->maxes[i]= (float*) malloc(halfAudioBlockSize * sizeof(float));
		ep_extractor->mags[i] = (float*) malloc(halfAudioBlockSize * sizeof(float));
	}

  	ep_extractor->filterIndex = 0;

  	if(config->printDebugInfo){
  		ep_extractor->spectrogram_file = fopen("spectrogram.csv", "w");
  		ep_extractor->maxes_file = fopen("maxes.csv", "w");
  	}

  	return ep_extractor;
}

void olaf_ep_extractor_destroy(Olaf_EP_Extractor * ep_extractor){

	if(ep_extractor->config->printDebugInfo){
		fclose(ep_extractor->maxes_file);
		fclose(ep_extractor->spectrogram_file);
	}

	free(ep_extractor->eventPoints.eventPoints);
	
	free(ep_extractor->horizontalMaxes);

	for(int i = 0; i < ep_extractor->config->filterSizeTime ;i++){
	  free(ep_extractor->maxes[i]);
	  free(ep_extractor->mags[i]);
  	}

  	free(ep_extractor->maxes);
  	free(ep_extractor->mags);

  	free(ep_extractor);
}

void printMagsToFile(Olaf_EP_Extractor * ep_extractor,float* mags){
	
	int halfAudioBlockSize = ep_extractor->config->audioBlockSize/2;

	for(int i = 0 ; i <  halfAudioBlockSize ; i++){
		fprintf(ep_extractor->spectrogram_file,"%f ,",mags[i]);
	}

	fprintf(ep_extractor->spectrogram_file,"\n");
}

void printMaxesToFile(Olaf_EP_Extractor * ep_extractor,float* maxes){
	
	int halfAudioBlockSize = ep_extractor->config->audioBlockSize/2;

	for(int i = 0 ; i <  halfAudioBlockSize ; i++){
		fprintf(ep_extractor->maxes_file,"%f ,",maxes[i]);
	}
	fprintf(ep_extractor->maxes_file,"\n");
}


void printMaxesToFileWithEventPoints(Olaf_EP_Extractor * ep_extractor,float* maxes){
	
	int halfAudioBlockSize = ep_extractor->config->audioBlockSize/2;

	for(int i = 0 ; i <  halfAudioBlockSize ; i++){

		struct eventpoint foundEP;
		foundEP.timeIndex = -1;

		for(int j = 0 ; j <  ep_extractor->config->maxEventPoints ; j++){
			struct eventpoint ep = ep_extractor->eventPoints.eventPoints[j];
			int timeIndex = ep_extractor->audioBlockIndex - ep_extractor->config->halfFilterSizeTime;

			if(ep.timeIndex== timeIndex && ep.frequencyBin == i){
				foundEP = ep;
			}
		}

		if(foundEP.timeIndex>0){
			fprintf(ep_extractor->maxes_file,"%f ,",maxes[i]*100);
		}else{
			fprintf(ep_extractor->maxes_file,"%f ,",0.0);
		}	
	}
	fprintf(ep_extractor->maxes_file,"\n");
}

void olaf_ep_extractor_max_filter_time(float* data[],float * max,int length,int filterSize){
	for(int i = 0 ; i < length;i++){
		max[i] = -10000000;
		for(int j = 0 ; j < filterSize; j++){
			if(data[j][i]>max[i])
				max[i]=data[j][i];
		}
	}
}

void olaf_ep_extractor_max_filter_frequency(float* data, float * max, int length,int half_filter_size ){
	for(int i = 0 ; i < length;i++){
		int startIndex = i - half_filter_size > 0 ? i - half_filter_size : 0;
		int stopIndex = i + half_filter_size < length ? i + half_filter_size + 1: length;
		max[i] = -100000;
		for(int j = startIndex ; j < stopIndex; j++){
			if(data[j]>max[i])
				max[i]=data[j];
		}
	}
}

void extract_internal(Olaf_EP_Extractor * ep_extractor){

	olaf_ep_extractor_max_filter_time(ep_extractor->maxes,ep_extractor->horizontalMaxes,ep_extractor->config->audioBlockSize/2, ep_extractor->config->filterSizeTime);

	int halfFilterSizeTime = ep_extractor->config->halfFilterSizeTime;
	int halfAudioBlockSize = ep_extractor->config->audioBlockSize/2;
	struct eventpoint * eventPoints = ep_extractor->eventPoints.eventPoints;
	int eventPointIndex = ep_extractor->eventPoints.eventPointIndex;

	//do not start at zero 
	for(int j = 1 ; j < halfAudioBlockSize - 1 ; j++){
		float maxVal = ep_extractor->horizontalMaxes[j];
		float currentVal = ep_extractor->mags[halfFilterSizeTime][j];

		if(currentVal == maxVal && maxVal > ep_extractor->config->minEventPointMagnitude){
			int timeIndex = ep_extractor->audioBlockIndex - halfFilterSizeTime;
			int frequencyBin = j;
			float magnitude = ep_extractor->mags[halfFilterSizeTime][frequencyBin];
			
			eventPoints[eventPointIndex].timeIndex = timeIndex;
			eventPoints[eventPointIndex].frequencyBin = frequencyBin;
			eventPoints[eventPointIndex].magnitude = magnitude;

			//fprintf(stderr,"Found ep at %d time index %d f bin %.06f mag \n",timeIndex,frequencyBin,magnitude);
			
			eventPointIndex++;
		}
	}
	
	// do not forget to set the event point index for the next run
	ep_extractor->eventPoints.eventPointIndex = eventPointIndex;

	if(ep_extractor->config->printDebugInfo){

		if(ep_extractor->audioBlockIndex==ep_extractor->config->filterSizeTime-1){
			for(int i = 0 ; i < ep_extractor->config->halfFilterSizeTime ; i++){
				printMaxesToFileWithEventPoints(ep_extractor,ep_extractor->maxes[i]);
			}
		}

		//To print the maxes withouth horizontal max filter
		//int halfFilterIndex = (filterSize)/2;
		//float* maxes = ep_extractor->maxes[halfFilterIndex];
		printMaxesToFileWithEventPoints(ep_extractor,ep_extractor->horizontalMaxes);

		//Print maxes with horizontal max filter
		//printMaxesToFileWithEventPoints(ep_extractor,ep_extractor->horizontalMaxes);
	}
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

struct extracted_event_points * olaf_ep_extractor_extract(Olaf_EP_Extractor * ep_extractor, float* fft_out, int audioBlockIndex){

	int filterIndex = ep_extractor->filterIndex;

	ep_extractor->audioBlockIndex = audioBlockIndex;

	int magnitudeIndex = 0;
	for(int j = 0 ; j < ep_extractor->config->audioBlockSize ; j+=2){
		ep_extractor->mags[filterIndex][magnitudeIndex] = fft_out[j] * fft_out[j] + fft_out[j+1] * fft_out[j+1];
		magnitudeIndex++;
	}

	if(ep_extractor->config->printDebugInfo){
		printMagsToFile(ep_extractor,ep_extractor->mags[filterIndex]);
	}

	//process the fft frame in time (vertically)
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
