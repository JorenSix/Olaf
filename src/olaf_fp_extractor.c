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
#include <stdbool.h>
#include <assert.h>
#include <math.h>

#include "olaf_fp_extractor.h"
#include "olaf_config.h"


struct Olaf_FP_Extractor{
	int audioBlockIndex;
	struct extracted_fingerprints fingerprints;
	Olaf_Config * config;
	size_t total_fp_extracted;
	bool warning_given;
};

Olaf_FP_Extractor * olaf_fp_extractor_new(Olaf_Config * config){

	Olaf_FP_Extractor *fp_extractor = (Olaf_FP_Extractor *) malloc(sizeof(Olaf_FP_Extractor));

	fp_extractor->warning_given = false;
	
	fp_extractor->config = config;

	fp_extractor->fingerprints.fingerprints = (struct fingerprint *) calloc(config->maxFingerprints , sizeof(struct fingerprint));

	fp_extractor->fingerprints.fingerprintIndex = 0;
	fp_extractor->total_fp_extracted=0;

	return fp_extractor;
}

void olaf_fp_extractor_destroy(Olaf_FP_Extractor * fp_extractor){
	free(fp_extractor->fingerprints.fingerprints);
	free(fp_extractor);
}

int olaf_ep_compare_event_points (const void * a, const void * b) {
	struct eventpoint aPoint = *(struct eventpoint*) a;
	struct eventpoint bPoint = *(struct eventpoint*) b;
	return (aPoint.timeIndex - bPoint.timeIndex);
}

size_t olaf_fp_extractor_total(Olaf_FP_Extractor * fp_extractor){
	return fp_extractor->total_fp_extracted;
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
uint64_t olaf_fp_extractor_hash(struct fingerprint f){
	int f1 = f.frequencyBin1;
	int f2 = f.frequencyBin2;
	int f3 = f.frequencyBin3;

	int t1 = f.timeIndex1;
	int t2 = f.timeIndex2;
	int t3 = f.timeIndex3;

	float m1 = f.magnitude1;
	float m2 = f.magnitude2;
	float m3 = f.magnitude3;

	uint64_t f1LargerThanF2 = f2 > f3 ? 1 : 0;
	uint64_t f2LargerThanF3 = f2 > f3 ? 1 : 0;
	uint64_t f3LargerThanF1 = f3 > f1 ? 1 : 0;

	uint64_t m1LargerThanm2 = m1 > m2 ? 1 : 0;
	uint64_t m2LargerThanm3 = m2 > m3 ? 1 : 0;
	uint64_t m3LargerThanm1 = m3 > m1 ? 1 : 0;
	
	m1LargerThanm2 = 0;
	m2LargerThanm3 = 0;
	m3LargerThanm1 = 0;

	uint64_t dt1t2LargerThant3t2 = (t2 - t1) > (t3 - t2) ? 1 : 0;
	uint64_t df1f2LargerThanf3f2 = abs(f2 - f1) > abs(f3 - f2) ? 1 : 0;

	//9 bits f in range( 0 - 512) to 8 bits
	uint64_t f1Range = (f1 >> 1);
		
	//7 bits (0-128) -> 5 bits
	uint64_t df2f1 = (abs(f2 - f1) >> 2);
	uint64_t df3f2 = (abs(f3 - f2) >> 2);
		
	//6 bits max
	uint64_t diffT = (t3 - t1);

	uint64_t hash = 
				((diffT                &  ((1<<6)  -1)   ) << 0 ) +
		        ((f1LargerThanF2       &  ((1<<1 ) -1)   ) << 6 ) +
		        ((f2LargerThanF3       &  ((1<<1 ) -1)   ) << 7 ) +
		        ((f3LargerThanF1       &  ((1<<1 ) -1)   ) << 8 ) +
		        ((m1LargerThanm2       &  ((1<<1 ) -1)   ) << 9 ) +
		        ((m2LargerThanm3       &  ((1<<1 ) -1)   ) << 10) +
		        ((m3LargerThanm1       &  ((1<<1 ) -1)   ) << 11) +
		        ((dt1t2LargerThant3t2  &  ((1<<1 ) -1)   ) << 12) +
		        ((df1f2LargerThanf3f2  &  ((1<<1 ) -1)   ) << 13) +
		        ((f1Range              &  ((1<<8 ) -1)   ) << 14) +
		        ((df2f1                &  ((1<<6 ) -1)   ) << 22) +
		        ((df3f2                &  ((uint64_t) (1<<6 ) -1)   ) << 28) ;
	
	return hash;
}

void olaf_fp_extractor_print(struct fingerprint f){
	fprintf(stderr,"FP hash: %llu \n", olaf_fp_extractor_hash(f));
	fprintf(stderr,"\tt1: %d, f1: %d, m1: %.3f\n", f.timeIndex1,f.frequencyBin1,f.magnitude1);
	fprintf(stderr,"\tt2: %d, f2: %d, m2: %.3f\n", f.timeIndex2,f.frequencyBin2,f.magnitude2);
	fprintf(stderr,"\tt3: %d, f3: %d, m3: %.3f\n", f.timeIndex3,f.frequencyBin3,f.magnitude3);
}

struct extracted_fingerprints * olaf_fp_extractor_extract(Olaf_FP_Extractor * fp_extractor,struct extracted_event_points * eventPoints,int audioBlockIndex){
	
	if(fp_extractor->config->verbose){
		fprintf(stderr,"Combining event points into fingerprints: \n");
		for(int i = 0 ; i < eventPoints->eventPointIndex ; i++){
			fprintf(stderr,"\t idx: %d ",i);
			olaf_ep_extractor_print_ep(eventPoints->eventPoints[i]);
		}
	}
	
	for(int i = 0; i < eventPoints->eventPointIndex ; i++){

		int t1 = eventPoints->eventPoints[i].timeIndex;
		int f1 = eventPoints->eventPoints[i].frequencyBin;
		float m1 =  eventPoints->eventPoints[i].magnitude;

		//do not evaluate empty points
		if(f1==0 && t1==0)
			break;

		//do not evaluate event points that are too recent
		int diffToCurrentTime = audioBlockIndex-fp_extractor->config->maxTimeDistance;
		if(t1>diffToCurrentTime)
			break;

		for(int j = i+1; j < eventPoints->eventPointIndex; j++){

			int t2 =  eventPoints->eventPoints[j].timeIndex;
			int f2 =  eventPoints->eventPoints[j].frequencyBin;
			float m2 =  eventPoints->eventPoints[j].magnitude;

			int fDiff = abs(f1 - f2);
			int tDiff = t2-t1;

			assert(t2>=t1);
			assert(tDiff>=0);

			//do not evaluate points to far in the future
			if(tDiff > fp_extractor->config->maxTimeDistance)
				break;

			if(tDiff >= fp_extractor->config->minTimeDistance && 
				tDiff <= fp_extractor->config->maxTimeDistance && 
				fDiff >= fp_extractor->config->minFreqDistance && 
				fDiff <= fp_extractor->config->maxFreqDistance){

				assert(t2>t1);

				for(int k = j+1; k < eventPoints->eventPointIndex; k++){

					int t3 =  eventPoints->eventPoints[k].timeIndex;
					int f3 =  eventPoints->eventPoints[k].frequencyBin;
					float m3 =  eventPoints->eventPoints[k].magnitude;

					//do not evaluate points to far in the future
					if(tDiff > fp_extractor->config->maxTimeDistance)
						break;

					fDiff = abs(f2 - f3);
					tDiff = t3-t2;
					assert(t3>=t2);
					assert(tDiff>=0);

					if(	tDiff >= fp_extractor->config->minTimeDistance && 
						tDiff <= fp_extractor->config->maxTimeDistance && 
						fDiff >= fp_extractor->config->minFreqDistance && 
						fDiff <= fp_extractor->config->maxFreqDistance){

						assert(t3>t2);

						if(fp_extractor->fingerprints.fingerprintIndex >=  fp_extractor->config->maxFingerprints){
							// We have reached the max amount of fingerprints we can store in this batch
							// This can mean a lot of fingerprints at the same time: 
							//so not much is lost when this happens
							if(!fp_extractor->warning_given){
								fprintf(stderr,"Warning: Fingerprint maximum index %zu reached, fingerprints are ignored, consider increasing config->maxFingerprints if you see this often. \n",fp_extractor->fingerprints.fingerprintIndex);
								fp_extractor->warning_given = true;
							}
						}else{


							//temporarily store (do not increment fingerprint index, unless it is not yet discovered)
							fp_extractor->fingerprints.fingerprints[fp_extractor->fingerprints.fingerprintIndex].timeIndex1 = t1;
							fp_extractor->fingerprints.fingerprints[fp_extractor->fingerprints.fingerprintIndex].timeIndex2 = t2;
							fp_extractor->fingerprints.fingerprints[fp_extractor->fingerprints.fingerprintIndex].timeIndex3 = t3;

							fp_extractor->fingerprints.fingerprints[fp_extractor->fingerprints.fingerprintIndex].frequencyBin1 = f1;				
							fp_extractor->fingerprints.fingerprints[fp_extractor->fingerprints.fingerprintIndex].frequencyBin2 = f2;
							fp_extractor->fingerprints.fingerprints[fp_extractor->fingerprints.fingerprintIndex].frequencyBin3 = f3;
							
							fp_extractor->fingerprints.fingerprints[fp_extractor->fingerprints.fingerprintIndex].magnitude1 = m1;				
							fp_extractor->fingerprints.fingerprints[fp_extractor->fingerprints.fingerprintIndex].magnitude2 = m2;
							fp_extractor->fingerprints.fingerprints[fp_extractor->fingerprints.fingerprintIndex].magnitude3 = m3;

							if(fp_extractor->config->verbose){
								fprintf(stderr,"Fingerprint at index %zu\n",fp_extractor->fingerprints.fingerprintIndex);
								olaf_fp_extractor_print(fp_extractor->fingerprints.fingerprints[fp_extractor->fingerprints.fingerprintIndex]);
							}
							
							fp_extractor->fingerprints.fingerprintIndex++;
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
			eventPoints->eventPoints[i].timeIndex = 1<<23;
			eventPoints->eventPoints[i].frequencyBin = 0;
			eventPoints->eventPoints[i].magnitude = 0;
		}
	}

	//sort the array from low timeIndex to high
	//the marked event points have a high time index
	//qsort(eventPoints->eventPoints,fp_extractor->config->maxEventPoints, sizeof(struct eventpoint), olaf_ep_compare_event_points);
	qsort(eventPoints->eventPoints,fp_extractor->config->maxEventPoints, sizeof(struct eventpoint), olaf_ep_compare_event_points);

	//find the first marked event point: this is where the next point needs to be stored
	for(int i = 0 ; i <eventPoints->eventPointIndex ; i++){

		if(eventPoints->eventPoints[i].timeIndex == 1<<23){
			//the next point needs to be stored at this index
			eventPoints->eventPointIndex  = i;
			break;
		}
	}

	fp_extractor->total_fp_extracted+=fp_extractor->fingerprints.fingerprintIndex;
	//eventPoints->eventPointIndex  = 0;
	/*
	fprintf(stderr,"New EP index %d \n",eventPoints->eventPointIndex);
	for(int i = 0 ; i < eventPoints->eventPointIndex ; i++){
		fprintf(stderr,"idx:%d ",i);
		olaf_ep_extractor_print_ep(eventPoints->eventPoints[i]);
	}
	*/

	return &fp_extractor->fingerprints;
}
