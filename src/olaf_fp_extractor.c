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
#include <assert.h>
#include <math.h>

#include "olaf_fp_extractor.h"
#include "olaf_config.h"


struct Olaf_FP_Extractor{
	int audioBlockIndex;
	struct extracted_fingerprints fingerprints;
	uint32_t * recentFingerprints;
	int recentFingerprintIndex;
	Olaf_Config * config;
};

Olaf_FP_Extractor * olaf_fp_extractor_new(Olaf_Config * config){

	Olaf_FP_Extractor *fp_extractor = (Olaf_FP_Extractor*) malloc(sizeof(Olaf_FP_Extractor));

	fp_extractor->config = config;

	fp_extractor->recentFingerprintIndex = 0;

	fp_extractor->recentFingerprints = (uint32_t *) malloc(config->recentFingerprintSize * sizeof(uint32_t));

	fp_extractor->fingerprints.fingerprints = (struct fingerprint*) malloc(config->maxFingerprints * sizeof(struct fingerprint));

	fp_extractor->fingerprints.fingerprintIndex = 0;

	return fp_extractor;
}

void olaf_fp_extractor_destroy(Olaf_FP_Extractor * fp_extractor){
	free(fp_extractor->fingerprints.fingerprints);
	free(fp_extractor->recentFingerprints);
	free(fp_extractor);
}

int olaf_ep_compare_event_points (const void * a, const void * b) {
	struct eventpoint aPoint = *(struct eventpoint*) a;
	struct eventpoint bPoint = *(struct eventpoint*) b;
	return (aPoint.timeIndex - bPoint.timeIndex);
}

// Calculates a hash from a fingerprint struct. A hash fits in a 32bit unsigned int.
//
// The hash consists of time info and time independent info.
// The LSB's of the hash are used to store the time information.
// This makes it so that when the hashes are stored __in order__ matches can be 
// found using the MSB's.
//
// An example: say that the MSB part is 1546 and the time info 11, 
// combined this makes 154611
// The reference database contains for example:
//
// ...
// 1000 17
// 1264 20
// 1164 01
// 1164 07
// 1546 12 <--
// 1546 14 <--
// 1546 19 <--
// 1546 77 <--
// 1687 16
// ...
//
//A binary search for 1546xx in the reference database ends up at one of the above arrows. 
//Subsequently all the 1546xx values are identified by iteration in both directions.
//
uint32_t olaf_fp_extractor_hash(struct fingerprint f){

	//hash components
	uint16_t deltaT1 = (f.timeIndex2 - f.timeIndex1);
	uint16_t deltaT2 = (f.timeIndex3 - f.timeIndex2)/2;

	uint16_t f1LargerThanF2 = f.frequencyBin1 > f.frequencyBin2 ? 1 : 0;
	uint16_t f2LargerThanF3 = f.frequencyBin2 > f.frequencyBin3 ? 1 : 0;
	
	uint16_t frequencyBin1 = f.frequencyBin1;
	
	uint16_t deltaF1=abs(f.frequencyBin1 - f.frequencyBin2);
	uint16_t deltaF2=abs(f.frequencyBin2 - f.frequencyBin3);

	//fprintf(stderr,"f1: %0.3f  f1i: %d  f2: %0.3f f2i: %d  deltaF: %d deltaFi: %d \n",f.fractionalFrequencyBin1, (uint16_t) round(f.fractionalFrequencyBin1 * f_mul), f.fractionalFrequencyBin2, (uint16_t) round(f.fractionalFrequencyBin2 * f_mul), deltaFInterpolated, deltaFInterpolated);     
	
	//combine the hash components into a single 32 bit integer
	uint32_t fp_hash = 
			((frequencyBin1            &  ((1<<8 ) -1)   ) << 26) +
	        ((f2LargerThanF3           &  ((1<<1 ) -1)   ) << 25) +
	        ((f1LargerThanF2           &  ((1<<1 ) -1)   ) << 24) +
	        ((deltaF1                  &  ((1<<7 ) -1)   ) << 17) +
	        ((deltaF2                  &  ((1<<7 ) -1)   ) << 10) +
	        ((deltaT2                  &  ((1<<5 ) -1)   ) <<  5) +
	        ((deltaT1                  &  ((1<<5 ) -1)   ) <<  0) ;

	return fp_hash;
}

struct extracted_fingerprints * olaf_fp_extractor_extract(Olaf_FP_Extractor * fp_extractor,struct extracted_event_points * eventPoints,int audioBlockIndex){
	for(int i = 0; i < eventPoints->eventPointIndex ; i++){

		int t1 = eventPoints->eventPoints[i].timeIndex;
		int f1 = eventPoints->eventPoints[i].frequencyBin;
		int ppp1 = eventPoints->eventPoints[i].printsPerPoint;

		//do not evaluate empty points
		if(f1==0 && t1==0)
			break;

		//do not evaulate points with more than x prints per event point
		if(ppp1>fp_extractor->config->maxFingerprintsPerPoint)
			continue;

		//do not evaluate event points that are too recent
		int diffToCurrentTime = audioBlockIndex-fp_extractor->config->maxTimeDistance;
		if(t1>diffToCurrentTime)
			break;

		for(int j = i+1; j < eventPoints->eventPointIndex; j++){

			int t2 =  eventPoints->eventPoints[j].timeIndex;
			int f2 =  eventPoints->eventPoints[j].frequencyBin;
			int ppp2 =  eventPoints->eventPoints[j].printsPerPoint;

			int fDiff = abs(f1 - f2);
			int tDiff = t2-t1;

			assert(t2>=t1);

			//do not evaluate points to far in the future
			if(tDiff > fp_extractor->config->maxTimeDistance)
				break;

			//do not evaulate points with more than x prints per event point
			if(ppp2>fp_extractor->config->maxFingerprintsPerPoint)
				continue;

			if(tDiff >= fp_extractor->config->minTimeDistance && 
				tDiff <= fp_extractor->config->maxTimeDistance && 
				fDiff >= fp_extractor->config->minFreqDistance && 
				fDiff <= fp_extractor->config->maxFreqDistance){

				assert(t2>t1);

				for(int k = j+1; k < eventPoints->eventPointIndex; k++){

					int t3 =  eventPoints->eventPoints[k].timeIndex;
					int f3 =  eventPoints->eventPoints[k].frequencyBin;
					int ppp3 =  eventPoints->eventPoints[k].printsPerPoint;

					//do not evaluate points to far in the future
					if(tDiff > fp_extractor->config->maxTimeDistance)
						break;

					//do not evaulate points with more than x prints per event point
					if(ppp3>fp_extractor->config->maxFingerprintsPerPoint)
						continue;

					fDiff = abs(f2 - f3);
					tDiff = t3-t2;

					if(	tDiff >= fp_extractor->config->minTimeDistance && 
						tDiff <= fp_extractor->config->maxTimeDistance && 
						fDiff >= fp_extractor->config->minFreqDistance && 
						fDiff <= fp_extractor->config->maxFreqDistance){

						//temporarily store (do not increment fingerprint index, unless it is not yet discovered)
						fp_extractor->fingerprints.fingerprints[fp_extractor->fingerprints.fingerprintIndex].timeIndex1 = t1;
						fp_extractor->fingerprints.fingerprints[fp_extractor->fingerprints.fingerprintIndex].timeIndex2 = t2;
						fp_extractor->fingerprints.fingerprints[fp_extractor->fingerprints.fingerprintIndex].timeIndex3 = t3;
						fp_extractor->fingerprints.fingerprints[fp_extractor->fingerprints.fingerprintIndex].frequencyBin1 = f1;				
						fp_extractor->fingerprints.fingerprints[fp_extractor->fingerprints.fingerprintIndex].frequencyBin2 = f2;
						fp_extractor->fingerprints.fingerprints[fp_extractor->fingerprints.fingerprintIndex].frequencyBin3 = f3;

						uint32_t fingerprintHash = olaf_fp_extractor_hash(fp_extractor->fingerprints.fingerprints[fp_extractor->fingerprints.fingerprintIndex]);

						//check if it is already discovered
						bool newFingerprint = true;
						for(int k = 0 ; k < fp_extractor->config->recentFingerprintSize ; k++ ){
							if(fingerprintHash == fp_extractor->recentFingerprints[k]){
								newFingerprint = false;
								break;
							}
						}

						if(newFingerprint){
							eventPoints->eventPoints[i].printsPerPoint++;
							eventPoints->eventPoints[j].printsPerPoint++;

							//int fDiffBins = abs(f1 - f2);
							//fprintf(stderr,"t1: %d  t2: %d  tdiff: %d (bins) f1: %d f2: %d  fdiff: %d (cents) fdiff: %d (bins)\n",t1,t2,tDiff,f1,f2,fDiff,fDiffBins);
							
							fp_extractor->fingerprints.fingerprintIndex++;

							fp_extractor->recentFingerprints[fp_extractor->recentFingerprintIndex] = fingerprintHash;
							fp_extractor->recentFingerprintIndex++;
							if(fp_extractor->recentFingerprintIndex == fp_extractor->config->recentFingerprintSize)
								fp_extractor->recentFingerprintIndex=0;

						}
					}
				}
			}
		}
	}

	int cutoffTime = eventPoints->eventPoints[eventPoints->eventPointIndex-1].timeIndex - fp_extractor->config->maxTimeDistance;

	//prepare the array for the next event loops
	for(int i = 0 ; i < eventPoints->eventPointIndex ; i++){

		//mark the event points that are too old
		if(eventPoints->eventPoints[i].timeIndex <= cutoffTime){
			eventPoints->eventPoints[i].timeIndex = 1<<16;
			eventPoints->eventPoints[i].printsPerPoint = 0;
			eventPoints->eventPoints[i].frequencyBin = 0;
			eventPoints->eventPoints[i].magnitude = 0;
		}

		//mark the event points that are used the max number of times
		if(eventPoints->eventPoints[i].printsPerPoint > fp_extractor->config->maxFingerprintsPerPoint){
			eventPoints->eventPoints[i].timeIndex = 1<<16;
			eventPoints->eventPoints[i].printsPerPoint = 0;
			eventPoints->eventPoints[i].frequencyBin = 0;
		}
	}

	//sort the array from low timeIndex to high
	//the marked event points have a high time index
	qsort(eventPoints->eventPoints,eventPoints->eventPointIndex, sizeof(struct eventpoint), olaf_ep_compare_event_points);

	//find the first marked event point: this is where the next point needs to be stored
	for(int i = 0 ; i <eventPoints->eventPointIndex ; i++){

		if(eventPoints->eventPoints[i].timeIndex==1<<16){
			//the next point needs to be stored at this index
			//fprintf(stderr,"New event point index %d , old index %d,  current time %d (%d ms) , cutoff time %d \n",i,eventPoints->eventPointIndex,audioBlockIndex,audioBlockIndex * 32,cutoffTime);
			eventPoints->eventPointIndex  = i;

			//for(int j = 0 ; j < eventPoints->eventPointIndex ; j++){
			//	fprintf(stderr,"\tNew ev %d %d %d\n",eventPoints->eventPoints[j].timeIndex,eventPoints->eventPoints[j].frequencyBin,eventPoints->eventPoints[j].printsPerPoint); 
			//}

			break;
		}
	}
	//fprintf(stderr,"New ev\n");

	return &fp_extractor->fingerprints;
}
