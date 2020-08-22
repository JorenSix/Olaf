//Standard extraction:
//	* 8000Hz sample rate,
//	* FFT size of 512 audio samples (bin = 8000)
//	* 256 audio sample step size (50% overlap) or 256 / 8000 = 32 milliseconds
//
// Event points:

// to create ref.raw use e.g.
// ffmpeg -i ../dataset/english.opus -ac 1  -ar 8000 -f f32le -acodec pcm_f32le ../extractor/ref.raw

#include <stdio.h>
#include <stdbool.h>
#include <stdlib.h>
#include <stdint.h>
#include <math.h>

#include "refprints.h"
#include "bincenters.h"
#include "eventpoints.h"

struct eventpoint {
	int frequencyBin;
	int timeIndex;
	float contrast;
	uint8_t printsPerPoint;
};

#define maxEventPoints 512
#define maxEventPointsPerBlock 5

struct eventpoint eventPoints[maxEventPoints];
struct eventpoint currEventPoints[maxEventPointsPerBlock];//max three event points per fft column
int eventPointIndex = 0;

struct result{
	int timeDiff;
	int lastUpdatedTimeIndex;
	int matchCount;
};

struct fingerprint{
	int frequencyBin1;
	int timeIndex1;
	int frequencyBin2;
	int timeIndex2;
};

#define filterSize 9//The size of the max filter is 64ms * 13
float* maxes[filterSize];
float* mags[filterSize];
float horizontalMaxes[halfAudioBlockSize];
int frameIndex=0;
int filterIndex=0;
const float minContrast = 1.4; // the event point needs some contrast vs environment


// no more than three event points per analysis window

const int minTimeDistance = 3; // 64ms x 5 for fingerprint construction
const int maxTimeDistance = minTimeDistance + (1<<4); //64ms x 20 for fingerprint construction
const int minFreqDistance = 300; //cents for fingerprint construction
const int maxFreqDistance = 2400; //cents for fingerprint construction
const int maxFingerprintsPerPoint = 4;

//max number of event points = maxEventPointsPerBlock per frame of 64ms
//a fingerprint has maxTimeDistance of 17 blocks so
//maxTimeDistance x maxEventPointsPerBlock x 2 = 102

#define maxResults 60
const int maxResultAge = 500; //in time bins
struct result results[maxResults];
const int minMatchCount = 5;
const int goodMatchCount = 9;

FILE *spectrogram_file = NULL;
//fopen("spectrogram.csv", "w");
FILE *maxes_file = NULL;
//fopen("maxes.csv", "w");

#define recentFingerprintSize 10
uint32_t recentFingerprints[recentFingerprintSize];
int recentFingerprintIndex = 0;

int currentMatchScore = 0;
int matchDiff=0;//dif in audio blocks between current playback and reference

int compareEventPoints (const void * a, const void * b) {
	struct eventpoint aPoint = *(struct eventpoint*) a;
	struct eventpoint bPoint = *(struct eventpoint*) b;
	return (aPoint.timeIndex - bPoint.timeIndex);
}

int comparePrints(const void * a, const void * b){
	return ( (*(uint32_t*)a>>13) - (*(uint32_t*)b>>13) );
}

int compareResults (const void * a, const void * b) {
	struct result bResult = *(struct result*)b;
	struct result aResult = *(struct result*)a;
	return (bResult.matchCount - aResult.matchCount);
}

uint16_t unpackFingerprint(uint32_t packed){
	return packed & ((1<<13)-1);
}

uint32_t packFingerprint(struct fingerprint f){
	uint16_t frequency1 = f.frequencyBin1;
	uint16_t deltaF = abs(f.frequencyBin1 - f.frequencyBin2);
	uint16_t deltaT = f.timeIndex1 - f.timeIndex2;
	uint16_t f1LargerThanF2 = f.frequencyBin1 > f.frequencyBin2 ? 1 : 0;
	uint16_t time = f.timeIndex1;

	//frequency 0-255    -  8 bits           -  23
	//deltaF 0-31        -  5 bits           -  18
	//deltaT 0-15 1024ms -  4 bits           -  14
	//f1<f2  boolean     -  1 bits - 18 bits -  13
	//time   0 - 8192    - 13 bits - 31 bits -   0
	uint32_t packed = ((frequency1     &  ((1<<8) -1)   ) << 23) +
	                  ((deltaF         &  ((1<<5) -1)   ) << 18) +
	                  ((deltaT         &  ((1<<4) -1)   ) << 14) +
	                  ((f1LargerThanF2 &  ((1<<1) -1)   ) << 13) +
	                  ((time           &  ((1<<13)-1)   ) << 0 ) ;

	return packed;
}

void initResults(){
	for(int i = 0 ; i < maxResults ; i++){
		results[i].timeDiff=0;
		results[i].lastUpdatedTimeIndex = 0;
		results[i].matchCount = 0;
	}
}

void updateResults(int resultTimeDiff,int timeIndex){
	bool found = false;
	int maxMatchCount = 0;
	int maxMatchIndex = -1;

	//Serial.println(resultTimeDiff);

	for(int i = 0 ; i < maxResults ; i++){
		//printf("Results diff %d matchcount %d updated %d\n", results[i].timeDiff, results[i].matchCount, results[i].lastUpdatedTimeIndex);

		if(results[i].timeDiff==resultTimeDiff){
			results[i].lastUpdatedTimeIndex = timeIndex;
			results[i].matchCount = results[i].matchCount + 1;
			found = true;
		}

		if(results[i].matchCount > maxMatchCount){
			maxMatchIndex = i;
			maxMatchCount = results[i].matchCount;
		}
	}

	//state changes from no match to match or from match to good match:
	if((currentMatchScore<=minMatchCount && maxMatchCount > minMatchCount) || (currentMatchScore<=goodMatchCount && maxMatchCount > goodMatchCount) ){
		currentMatchScore = maxMatchCount;
	}
	currentMatchScore = maxMatchCount;

	if(maxMatchCount > minMatchCount){
		int diff = frameIndex - timeIndex;
		matchDiff = results[maxMatchIndex].timeDiff + diff;
	}

	int millisecond = (timeIndex-results[maxMatchIndex].timeDiff) * 35; //256 samples take 34816.5106 microseconds
	printf("Match score %d diff %d age %d  time %d (ms)\n", maxMatchCount,results[maxMatchIndex].timeDiff,timeIndex - results[maxMatchIndex].lastUpdatedTimeIndex,millisecond);
	
	qsort(results, maxResults, sizeof(struct result), compareResults);

	if(!found){
		// if not found replace the oldest match
		// with the current
		results[maxResults-1].timeDiff = resultTimeDiff;
		results[maxResults-1].lastUpdatedTimeIndex = timeIndex;
		results[maxResults-1].matchCount = 1;
	}
}

void ageResults(int timeIndex){
	for(int i = 0 ; i < maxResults ; i++){
		if(results[i].matchCount > 1){
		  int age = timeIndex - results[i].lastUpdatedTimeIndex;
			//Remove matches that are too old (age over max)
			// a negative age occurs when time overflows after 2^13 buffers (+- 8 min)
			// also remove these results
			if(age > maxResultAge || age < 0){
				//Serial.printf("Removed match that was too old: current time %d, result time %d , age %d, score %d\n",timeIndex,results[i].lastUpdatedTimeIndex,age,results[i].matchCount);
				//If the result is the current max, reset the indicator and the currentMatchScore
				//state change from match to no match
				if(results[i].matchCount == currentMatchScore){
						currentMatchScore = 1;
				}
				results[i].matchCount = 1;
			}
		}
	}
}

void matchPrint(uint32_t time,uint32_t packed){

	//printf("%u\n", packed );

	uint32_t * pItem;
	pItem = (uint32_t*) bsearch (&packed, refprints, refpintsLength, sizeof (uint32_t), comparePrints);
	if (pItem!=NULL){
		int index = pItem - refprints;
		int deltaTime = time - unpackFingerprint(refprints[index]);
		updateResults(deltaTime,time);
	}else{
		//Serial.printf("NOT FOUND %u\n", packed );
	}
}

//returns an index that indicates where to store the next event point
void extractFingerprints(int currentTimeIndex){

	for(int i = 0; i < maxEventPoints; i++){
		int t1 = eventPoints[i].timeIndex;
		int f1 = eventPoints[i].frequencyBin;
		int ppp1 = eventPoints[i].printsPerPoint;
		int f1Cents = binCenters[f1];

		//do not evaluate empty points
		if(f1==0 && t1==0)
			break;
		//do not evaulate points with more than x prints per event point
		if(ppp1>maxFingerprintsPerPoint)
			continue;

		//do not evaluate event points that are too recent
		int diffToCurrentTime = currentTimeIndex-maxTimeDistance;
		if(t1>diffToCurrentTime)
			break;

		for(int j = i+1; j < maxEventPoints; j++){

			int t2 = eventPoints[j].timeIndex;
			int f2 = eventPoints[j].frequencyBin;
			int ppp2 = eventPoints[j].printsPerPoint;
			int f2Cents = binCenters[f2];

			int fDiff = abs(f1Cents - f2Cents);
			int tDiff = t2-t1;

			//do evaluate points to far in the future
			if(tDiff > maxTimeDistance)
				break;

			//do not evaulate points with more than x prints per event point
			if(ppp2>maxFingerprintsPerPoint)
				continue;

			if(tDiff >= minTimeDistance && tDiff <= maxTimeDistance && fDiff >= minFreqDistance && tDiff <= maxFreqDistance){
				struct fingerprint f;
				f.timeIndex1 = t1;
				f.timeIndex2 = t2;
				f.frequencyBin1 = f1;
				f.frequencyBin2 = f2;

				uint32_t packed = packFingerprint(f);

				//check if it is already discovered
				bool newFingerprint = true;
				for(int k = 0 ; k < recentFingerprintSize ; k++ ){
					if(packed == recentFingerprints[k]){
						newFingerprint = false;
						break;
					}
				}

				if(newFingerprint){
					eventPoints[i].printsPerPoint = eventPoints[i].printsPerPoint + 1;
					eventPoints[j].printsPerPoint = eventPoints[j].printsPerPoint + 1;

					matchPrint(t1,packed);

					printf("%d %d %d %d %u\n",f.timeIndex1,f.timeIndex2,f.frequencyBin1,f.frequencyBin2,packed);
					

					recentFingerprints[recentFingerprintIndex] = packed;
					recentFingerprintIndex++;
					if(recentFingerprintIndex == recentFingerprintSize)
						recentFingerprintIndex=0;
				}
			}
		}
	}

	int cutoffTime = currentTimeIndex - maxTimeDistance*3;

	//prepare the array for the next event loops
	for(int i = 0 ; i < maxEventPoints ; i++){
		//mark the event points that are too old

	//	Serial.printf("%d %d \n",cutoffTime,eventPoints[i].timeIndex);
		if(eventPoints[i].timeIndex < cutoffTime){
			eventPoints[i].timeIndex = 1<<16;
			eventPoints[i].printsPerPoint = 0;
			eventPoints[i].frequencyBin = 0;
			eventPoints[i].contrast = 0;
		}

		//mark the event points that are used the max number of times
		if(eventPoints[i].printsPerPoint > maxFingerprintsPerPoint){
			eventPoints[i].timeIndex = 1<<16;
			eventPoints[i].printsPerPoint = 0;
			eventPoints[i].frequencyBin = 0;
			eventPoints[i].contrast = 0;
		}
	}

	//sort the array from low timeIndex to high
	//the marked event points have a high time index
	qsort(eventPoints,maxEventPoints, sizeof(struct eventpoint), compareEventPoints);

	//find the first marked event point: this is where the next point needs to be stored
	for(int i = 0 ; i <maxEventPoints ; i++){

		if(eventPoints[i].timeIndex==1<<16){
			//the next point needs to be stored at this index
			eventPointIndex = i;
			printf("New event point index %d  current time %d , cutoff time %d \n",i,currentTimeIndex,cutoffTime);
			break;
		}
	}
}

void resetEventPoints(){
	for(int i = 0 ; i <maxEventPoints ; i++){
		//struct eventpoint eventPoints
		eventPoints[i].timeIndex=0;
		eventPoints[i].frequencyBin = 0;
		eventPoints[i].printsPerPoint = 0;
	}
	eventPointIndex = 0;
}

void resetResults(){
	for(int i = 0 ; i < maxResults ; i++){
		results[i].matchCount=0;
	}
	currentMatchScore = 0;
}


void maxFilter(float* data, float * max, int length ){
	int halfFilterSize = filterSize / 2;
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

void horizontalMaxFilter(float* data[],float * max,int length){
	for(int i = 0 ; i < length;i++){
		max[i] = -10000000;
		for(int j = 0 ; j < filterSize; j++){
			if(data[j][i]>max[i])
				max[i]=data[j][i];
		}
	}
}

void rotate(){
	struct eventpoint temp = eventPoints[0];
	for(int i = 1 ; i < maxEventPoints;i++){
		eventPoints[i-1]=eventPoints[i];
	}
	eventPoints[maxEventPoints-1]=temp;
}

int findCurrEventPointIndex(struct eventpoint* currEventPoints){
	int indexWithMinimumContrast = 0;
	float minimumContrast = 10000;
	for(int i = 0 ; i < maxEventPointsPerBlock ; i++) {
		if(currEventPoints[i].contrast == -1 ){
			indexWithMinimumContrast = i;
			break;
		}
		if(minimumContrast > currEventPoints[i].contrast){
			minimumContrast = currEventPoints[i].contrast;
			indexWithMinimumContrast = i;
		}
	}
	return indexWithMinimumContrast;
}

void extractEventPointsAt(int bufferIndex){

	//prepare for reuse of the event points array
	for(int j = 0 ; j < maxEventPointsPerBlock ; j++){
		currEventPoints[j].timeIndex = -1;
		currEventPoints[j].frequencyBin = -1;
		currEventPoints[j].contrast = -1;
	}

	//process the current frames horizontally
	horizontalMaxFilter(maxes,horizontalMaxes,halfAudioBlockSize);

	for(int j = 0 ; j < halfAudioBlockSize ; j++){
		float maxVal = horizontalMaxes[j];
		float currentVal = mags[filterSize/2][j];

		if(currentVal == maxVal && currentVal != 0.0 ){
			int timeIndex = bufferIndex - filterSize/2;
			int binIndex = j;

			float contrastTime = 0;
			int nrOfBins = 0;
			for(int k = fmaxf(0,binIndex-filterSize/2); k < fminf(halfAudioBlockSize,binIndex+filterSize/2) ; k++){
				contrastTime+=mags[filterSize/2][k];
				nrOfBins++;
			}
			contrastTime  = contrastTime / (float) nrOfBins;

			float contrastFreq = 0;
			for(int k = 0; k < filterSize ; k++){
				contrastFreq+=mags[k][binIndex];
			}
			contrastFreq = contrastFreq / filterSize;

			float contrast = currentVal / fmaxf(contrastTime,contrastFreq);

			//the point needs to stand out vs environment
			if(contrast > minContrast){
				int minContrastIndex = findCurrEventPointIndex(currEventPoints);
				currEventPoints[minContrastIndex].timeIndex = timeIndex;
				currEventPoints[minContrastIndex].frequencyBin = binIndex;
				currEventPoints[minContrastIndex].contrast = contrast;
			}
		}
	}


	for(int j = 0 ; j < maxEventPointsPerBlock ; j++){

		if(currEventPoints[j].contrast == -1) break;

		int currentTimeIndex = bufferIndex - filterSize/2;

		eventPoints[eventPointIndex].timeIndex = currEventPoints[j].timeIndex ;
		eventPoints[eventPointIndex].frequencyBin = currEventPoints[j].frequencyBin;
		eventPoints[eventPointIndex].contrast = currEventPoints[j].contrast;

		eventPointIndex++;

		if(eventPointIndex == maxEventPoints){
			extractFingerprints(currentTimeIndex);
			eventPointIndex = 0;
		}


		/*
		float contrast = currEventPoints[j]->contrast;
		float binSizeInHz = ((float) audioSampleRate / 2.0)/ (float) audioBlockSize;
		float stepSizeInS = (float) audioStepSize / (float) audioSampleRate;
		//event point at the middle of the bin:
		float startTime = currEventPoints[j]->timeIndex  * stepSizeInS  + stepSizeInS / 2.0 ;
		float startFrequency = currEventPoints[j]->frequencyBin * binSizeInHz + binSizeInHz / 2.0 ;

		printf("%f, %f, %f\n",startTime,startFrequency,contrast);
		*/
	}

  	//shift the magnitudes to the right
	//temporarily keep a reference to the first buffer
	float* tempMax = maxes[0];
	float* tempMag = mags[0];
	//shift buffers by one
	for(int i = 1 ; i < filterSize ; i++){
		maxes[i-1]=maxes[i];
		mags[i-1]=mags[i];
	}
	//store the first at the last place
	maxes[filterSize-1] = tempMax;
	mags[filterSize-1] = tempMag;
}

void setupEventPointExtractor(){
	initResults();
	for(int i = 0; i < filterSize ;i++){
	  maxes[i] = (float*) malloc(halfAudioBlockSize*sizeof(float));
	  mags[i] =  (float*) malloc(halfAudioBlockSize*sizeof(float));
  	}
}

void destroyEventPointExtractor(){
	for(int i = 0; i < filterSize ;i++){
	  free(maxes[i]);
	  free(mags[i]);
  	}
}


void extractEventPoints(float* out,int bufferIndex){
	//calculate the magnitudes
	int mag_index = 0;
	for(int j = 0 ; j < audioBlockSize ; j+=2){
		mags[filterIndex][mag_index] = out[j] * out[j] + out[j+1] * out[j+1];
		mag_index++;
	}

	//process the fft frame
	maxFilter(mags[filterIndex],maxes[filterIndex],halfAudioBlockSize);

	if(filterIndex==filterSize-1){
		//enough history to extract event points
		extractEventPointsAt(bufferIndex);
	}else{
		//not enough history to extract event points
		filterIndex++;
	}
}
