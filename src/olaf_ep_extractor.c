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

	// The 'vertical' min-filtered magnitudes for the  
	float** mins;

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

	ep_extractor->currentEventPoints = (struct eventpoint*) malloc(config->maxEventPointsPerBlock * sizeof(struct eventpoint));

	ep_extractor->eventPoints.eventPoints = (struct eventpoint*) malloc(config->maxEventPoints * sizeof(struct eventpoint));
	ep_extractor->eventPoints.eventPointIndex = 0;
	
	ep_extractor->mags  = (float **) malloc(config->filterSize * sizeof(float *));
	ep_extractor->maxes = (float **) malloc(config->filterSize * sizeof(float *));

	for(int i = 0; i < config->filterSize ;i++){
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

	free(ep_extractor->currentEventPoints);
	
	free(ep_extractor->horizontalMaxes);

	for(int i = 0; i < ep_extractor->config->filterSize ;i++){
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
			int timeIndex = ep_extractor->audioBlockIndex - ep_extractor->config->halfFilterSize;

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

void horizontalMaxFilter(float* data[],float * max,int length,int filterSize){
	for(int i = 0 ; i < length;i++){
		max[i] = -10000000;
		for(int j = 0 ; j < filterSize; j++){
			if(data[j][i]>max[i])
				max[i]=data[j][i];
		}
	}
}

void maxFilter(float* data, float * max, int length,int halfFilterSize ){
	for(int i = 0 ; i < length;i++){
		int startIndex = i - halfFilterSize > 0 ? i - halfFilterSize : 0;
		int stopIndex = i + halfFilterSize < length ? i + halfFilterSize + 1: length;
		max[i] = -100000;
		for(int j = startIndex ; j < stopIndex; j++){
			if(data[j]>max[i])
				max[i]=data[j];
		}
	}
}

void minFilter(float* data, float * min, int length,int halfFilterSize ){
	for(int i = 0 ; i < length;i++){
		int startIndex = i - halfFilterSize > 0 ? i - halfFilterSize : 0;
		int stopIndex = i + halfFilterSize < length ? i + halfFilterSize + 1: length;
		min[i] = -100000;
		for(int j = startIndex ; j < stopIndex; j++){
			if(data[j]<min[i])
				min[i]=data[j];
		}
	}
}

void resetCurrentEventPoints(Olaf_EP_Extractor* ep_extractor){
	for(int i = 0 ; i < ep_extractor->config->maxEventPointsPerBlock ; i++){
		ep_extractor->currentEventPoints[i].timeIndex = -1;
		ep_extractor->currentEventPoints[i].frequencyBin = -1;
		ep_extractor->currentEventPoints[i].magnitude = -1;
		ep_extractor->currentEventPoints[i].printsPerPoint = 0;
	}
}

int findIndexWithMinimumMagnitude(Olaf_EP_Extractor * ep_extractor){
	int indexWithMinimumMagnitude = 0;
	float minimumMagnitude = 10000;
	for(int i = 0 ; i < ep_extractor->config->maxEventPointsPerBlock ; i++) {
		if(ep_extractor->currentEventPoints[i].magnitude == -1 ){
			indexWithMinimumMagnitude = i;
			break;
		}
		if(minimumMagnitude > ep_extractor->currentEventPoints[i].magnitude){
			minimumMagnitude = ep_extractor->currentEventPoints[i].magnitude;
			indexWithMinimumMagnitude = i;
		}
	}
	return indexWithMinimumMagnitude;
}

inline int max ( int a, int b ) { return a > b ? a : b; }
inline int min ( int a, int b ) { return a < b ? a : b; }

int compareEventPointsTimes (const void * a, const void * b) {
	struct eventpoint aPoint = *(struct eventpoint*) a;
	struct eventpoint bPoint = *(struct eventpoint*) b;
	return (aPoint.timeIndex - bPoint.timeIndex);
}

void extract_internal(Olaf_EP_Extractor * ep_extractor){

	horizontalMaxFilter(ep_extractor->maxes,ep_extractor->horizontalMaxes,ep_extractor->config->audioBlockSize/2, ep_extractor->config->filterSize);

	if(ep_extractor->config->printDebugInfo){
		//To print the maxes withouth horizontal max filter
		//int halfFilterIndex = (filterSize)/2;
		//float* maxes = ep_extractor->maxes[halfFilterIndex];
		//printMaxesToFile(ep_extractor,maxes);

		//Print maxes with horizontal max filter
		//printMaxesToFile(ep_extractor,ep_extractor->horizontalMaxes);
	}

	resetCurrentEventPoints(ep_extractor);

	int halfFilterSize = ep_extractor->config->halfFilterSize;
	int halfAudioBlockSize = ep_extractor->config->audioBlockSize/2;
	struct eventpoint * eventPoints = ep_extractor->eventPoints.eventPoints;
	int eventPointIndex = ep_extractor->eventPoints.eventPointIndex;

	for(int j = 0 ; j < halfAudioBlockSize ; j++){
		float maxVal = ep_extractor->horizontalMaxes[j];
		float currentVal = ep_extractor->mags[halfFilterSize][j];

		if(currentVal == maxVal && currentVal != 0.0){
			int timeIndex = ep_extractor->audioBlockIndex - halfFilterSize;
			int frequencyBin = j;

			float magnitude = ep_extractor->mags[ep_extractor->config->halfFilterSize][frequencyBin];

			float magnitudeSum = 0.0;

			for(int i = 0 ; i < ep_extractor->config->filterSize ; i++){
				magnitudeSum += ep_extractor->mags[i][frequencyBin];
				magnitudeSum += ep_extractor->mags[i][max(0  ,frequencyBin-1)];
				magnitudeSum += ep_extractor->mags[i][min(255,frequencyBin+1)];
				magnitudeSum += ep_extractor->mags[i][max(0  ,frequencyBin-2)];
				magnitudeSum += ep_extractor->mags[i][min(255,frequencyBin+2)];
			}
			float magnitudeAvg = magnitudeSum / (3. * (float) ep_extractor->config->filterSize);
			float contrast = magnitude / magnitudeAvg;
			
			float minContrast = ep_extractor->config->minContrast;

			//fprintf(stderr, "contrast: %f bin %d \n",contrast,frequencyBin);

			if(magnitude > ep_extractor->config->minMagnitude && contrast > minContrast ){
				int minMagnitudeIndex = findIndexWithMinimumMagnitude(ep_extractor);
				float minMagnitude = ep_extractor->currentEventPoints[minMagnitudeIndex].magnitude;

				if(magnitude>minMagnitude){
					//fprintf(stderr, "Magnitude: %f, minMagnitude: %f, minMagnitudeIndex: %d , time: %d \n",Magnitude,minMagnitude,minMagnitudeIndex,ep_extractor->audioBlockIndex);
					//gaussian interpolation
					//alpha is at f bin - 1
					//beta is at f bin  
					//gamma is at f bin + 1
					//see https://ccrma.stanford.edu/~jos/sasp/Quadratic_Interpolation_Spectral_Peaks.html
					float ym1, y0, yp1;
					//printf("Freq bin: %d\n",frequencyBin);
					ym1 = ep_extractor->mags[ep_extractor->config->halfFilterSize][max(0,frequencyBin-1)];
					y0 = magnitude;
					yp1 = ep_extractor->mags[ep_extractor->config->halfFilterSize][min(255,frequencyBin+1)];

					float fractionalOffset = log(yp1/ym1)/(2*log((y0 * y0) / (yp1 * ym1)));
					
					//assert(fractionalOffset <=  0.5);
					//assert(fractionalOffset >= -0.5);

					float fractionalFrequencyBin = frequencyBin + fractionalOffset;

					//printf("fract freq bin: %.2f freq bin: %d \n",fractionalFrequencyBin,frequencyBin);

					ep_extractor->currentEventPoints[minMagnitudeIndex].timeIndex = timeIndex;
					ep_extractor->currentEventPoints[minMagnitudeIndex].frequencyBin = frequencyBin;
					ep_extractor->currentEventPoints[minMagnitudeIndex].magnitude = magnitude;
					ep_extractor->currentEventPoints[minMagnitudeIndex].fractionalFrequencyBin = fractionalFrequencyBin;
				}
			}
		}
	}

	for(int i = 0 ; i < ep_extractor->config->maxEventPointsPerBlock ; i++) {
		if(ep_extractor->currentEventPoints[i].magnitude != -1 ){

			int closeEPIndex = eventPointIndex;
			//check if it is too close to an other event point
			for(int j =0 ; j < eventPointIndex ; j++){
				//if it is close

				if(eventPoints[j].timeIndex >= ep_extractor->currentEventPoints[i].timeIndex - 5
					&& 
					abs(eventPoints[j].frequencyBin - ep_extractor->currentEventPoints[i].frequencyBin) < 10){
					//the new event point is close to a previously detected ep, check the highest magnitude
					//fprintf(stderr,"close event points:  (%d %d) (%d %d)\n",eventPoints[j].timeIndex,eventPoints[j].frequencyBin,ep_extractor->currentEventPoints[i].timeIndex,ep_extractor->currentEventPoints[i].frequencyBin);
					closeEPIndex = j;
				}
			}

			//found no close EP, store a new EP:
			if(closeEPIndex==eventPointIndex){
				eventPoints[eventPointIndex].timeIndex = ep_extractor->currentEventPoints[i].timeIndex;
				eventPoints[eventPointIndex].frequencyBin = ep_extractor->currentEventPoints[i].frequencyBin;
				eventPoints[eventPointIndex].magnitude = ep_extractor->currentEventPoints[i].magnitude;
				eventPoints[eventPointIndex].fractionalFrequencyBin = ep_extractor->currentEventPoints[i].fractionalFrequencyBin;
				eventPoints[eventPointIndex].printsPerPoint = 0;

				eventPointIndex++;
			}else{
				//if the new ep has a higher magnitude, replace the prev ep  
				if(ep_extractor->currentEventPoints[i].magnitude > eventPoints[closeEPIndex].magnitude){
					eventPoints[closeEPIndex].timeIndex = ep_extractor->currentEventPoints[i].timeIndex;
					eventPoints[closeEPIndex].frequencyBin = ep_extractor->currentEventPoints[i].frequencyBin;
					eventPoints[closeEPIndex].magnitude = ep_extractor->currentEventPoints[i].magnitude;
					eventPoints[closeEPIndex].fractionalFrequencyBin = ep_extractor->currentEventPoints[i].fractionalFrequencyBin;
					eventPoints[closeEPIndex].printsPerPoint = 0;

					//sort by time
					qsort(eventPoints,eventPointIndex, sizeof(struct eventpoint), compareEventPointsTimes);

					//fprintf(stderr,"Replaced event points:  (%d %d) (%d %d)\n",eventPoints[closeEPIndex].timeIndex,eventPoints[closeEPIndex].frequencyBin,ep_extractor->currentEventPoints[i].timeIndex,ep_extractor->currentEventPoints[i].frequencyBin);
				}else{
					//fprintf(stderr,"Not replaced event points:  (%d %d) (%d %d)\n",eventPoints[closeEPIndex].timeIndex,eventPoints[closeEPIndex].frequencyBin,ep_extractor->currentEventPoints[i].timeIndex,ep_extractor->currentEventPoints[i].frequencyBin);
				}
				//do nothing, ignore the current EP

			}
			//fprintf(stderr, "ep index: %d \n",eventPointIndex);
		}
	}
	
	// do not forget to set the event point index for the next run
	ep_extractor->eventPoints.eventPointIndex = eventPointIndex;

	if(ep_extractor->config->printDebugInfo){

		if(ep_extractor->audioBlockIndex==ep_extractor->config->filterSize-1){
			for(int i = 0 ; i < ep_extractor->config->halfFilterSize ; i++){
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
	//float* tempMin = ep_extractor->mins[0];
	//shift buffers by one
	for(int i = 1 ; i < ep_extractor->config->filterSize ; i++){
		ep_extractor->maxes[i-1]=ep_extractor->maxes[i];
		ep_extractor->mags[i-1]=ep_extractor->mags[i];
	//	ep_extractor->mins[i-1]=ep_extractor->mins[i];	
	}
	
	//
	assert(ep_extractor->filterIndex == ep_extractor->config->filterSize-1);

	//store the first at the last place
	ep_extractor->maxes[ep_extractor->config->filterSize-1] = tempMax;
	//ep_extractor->mins[ep_extractor->config->filterSize-1] = tempMin;
	ep_extractor->mags[ep_extractor->config->filterSize-1] = tempMag;
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

	//process the fft frame vertically
	maxFilter(ep_extractor->mags[filterIndex],ep_extractor->maxes[filterIndex],ep_extractor->config->audioBlockSize/2,ep_extractor->config->halfFilterSize);

	if(filterIndex==ep_extractor->config->filterSize-1){
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
