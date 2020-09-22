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

#include "olaf_fp_matcher.h"
#include "olaf_fp_extractor.h"
#include "olaf_fp_db.h"

struct match_result{
	//The time difference between the query fingerprint t1 and
	//the reference fingerprint t1 time
	int timeDiff;

	// The time of the matched reference fingerprint t1 
	int referenceFingerprintT1;

	//The first found match in the reference for this time difference
	//Storing the first and last match makes it possible to identify
	//the matched secion in the reference audio
	int firstReferenceFingerprintT1;

	//The last found match in the reference for this time difference
	int lastReferenceFingerprintT1;

	//The time of the query fingerprint f1
	int queryFingerprintT1;

	//The number of occurences with this exact time difference
	int matchCount;

	//the matching audio file
	uint32_t matchIdentifier;

	//Current result should be printed?
	bool toPrint;
};

inline int max ( int a, int b ) { return a > b ? a : b; }
inline int min ( int a, int b ) { return a < b ? a : b; }


struct Olaf_FP_Matcher{

	//The list of results
	struct match_result * results;

	//the database to use
	Olaf_FP_DB * db;

	Olaf_Config * config;

	uint64_t * dbResults;
};

Olaf_FP_Matcher * olaf_fp_matcher_new(Olaf_Config * config,Olaf_FP_DB* db ){
	Olaf_FP_Matcher *fp_matcher = (Olaf_FP_Matcher*) malloc(sizeof(Olaf_FP_Matcher));

	fp_matcher->db = db;

	fp_matcher->dbResults = (uint64_t *) malloc(config->maxDBResults * sizeof(uint64_t));

	fp_matcher->config = config;

	fp_matcher->results = (struct match_result *) malloc(config->maxResults  * sizeof(struct match_result));

	//make sure every match field is initialized
	for(int i = 0 ; i < fp_matcher->config->maxResults ; i++){
		fp_matcher->results[i].timeDiff=0;
		fp_matcher->results[i].referenceFingerprintT1 = 0;
		fp_matcher->results[i].firstReferenceFingerprintT1 = 0;
		fp_matcher->results[i].lastReferenceFingerprintT1 = 0;
		fp_matcher->results[i].queryFingerprintT1 = 0;
		fp_matcher->results[i].matchCount = 0;
		fp_matcher->results[i].matchIdentifier = 0;
		fp_matcher->results[i].toPrint = false;
	}

	return fp_matcher;
}

int compareResults (const void * a, const void * b) {
	struct match_result aResult = *(struct match_result*)a;
	struct match_result bResult = *(struct match_result*)b;

	//first sort by match count from low to high
	int diff = (aResult.matchCount - bResult.matchCount);

	//if the match count is equal, sort by age
	// oldest (lowest t1) first
	if(diff == 0){
		diff = (aResult.queryFingerprintT1 - bResult.queryFingerprintT1);
	}

	return diff;
}

void updateResults(Olaf_FP_Matcher * fp_matcher,int queryFingerprintT1,int referenceFingerprintT1,uint32_t matchIdentifier){
	bool found = false;

	int timeDiff = queryFingerprintT1 - referenceFingerprintT1;

	for(int i = 0 ; i < fp_matcher->config->maxResults ; i++){

		//The time difference is expected to remain equal for a real match
		//The time difference to a certain match should remain equal
		if(fp_matcher->results[i].timeDiff==timeDiff && fp_matcher->results[i].matchIdentifier == matchIdentifier){
			fp_matcher->results[i].referenceFingerprintT1 = referenceFingerprintT1;
			fp_matcher->results[i].queryFingerprintT1 = queryFingerprintT1;
			fp_matcher->results[i].matchCount = fp_matcher->results[i].matchCount + 1;
			fp_matcher->results[i].toPrint = true;

			fp_matcher->results[i].firstReferenceFingerprintT1 = min(referenceFingerprintT1,fp_matcher->results[i].firstReferenceFingerprintT1);
			fp_matcher->results[i].lastReferenceFingerprintT1 = max(referenceFingerprintT1,fp_matcher->results[i].lastReferenceFingerprintT1);

			found = true;
			break;
		}
	}

	//sort results by match count, lowest match count first
	qsort(fp_matcher->results, fp_matcher->config->maxResults, sizeof(struct match_result), compareResults);

	//Replace the current lowest match with the new match
	if(!found){
		fp_matcher->results[0].referenceFingerprintT1 = referenceFingerprintT1;
		fp_matcher->results[0].firstReferenceFingerprintT1 = referenceFingerprintT1;
		fp_matcher->results[0].lastReferenceFingerprintT1 = referenceFingerprintT1;
		fp_matcher->results[0].queryFingerprintT1 = queryFingerprintT1;
		fp_matcher->results[0].matchCount = 1;
		fp_matcher->results[0].timeDiff=timeDiff;
		fp_matcher->results[0].matchIdentifier = matchIdentifier;
		fp_matcher->results[0].toPrint = false;
	}
}


void ageResults(Olaf_FP_Matcher * fp_matcher,int lastQueryFingerprintT1){

	//for each match age the match
	for(int i = 0 ; i < fp_matcher->config->maxResults ; i++){

		//skip empty slots
		if(fp_matcher->results[i].matchCount > 0){
			int age = lastQueryFingerprintT1 - fp_matcher->results[i].queryFingerprintT1;
			//Remove matches that are too old (age over max)
			// a negative age occurs when time overflows after 2^13 buffers (+- 8 min)
			// also remove these results
			//printf("Age:  %d , last: %d, current %d \n",age,lastQueryFingerprintT1,fp_matcher->results[i].queryFingerprintT1);
			if(fp_matcher->config->maxResultAge < age){
				//If the result is the current max, reset the indicator and the currentMatchScore
				fp_matcher->results[i].timeDiff = 0;
				fp_matcher->results[i].queryFingerprintT1 = 0;
				fp_matcher->results[i].referenceFingerprintT1 = 0;
				fp_matcher->results[i].firstReferenceFingerprintT1 = 0;
				fp_matcher->results[i].lastReferenceFingerprintT1 = 0;
				fp_matcher->results[i].matchCount = 0;
				fp_matcher->results[i].matchIdentifier = 0;
				fp_matcher->results[i].toPrint = false;
			}
		}
	}
}

void matchPrint(Olaf_FP_Matcher * fp_matcher,uint32_t queryFingerprintT1,uint32_t queryFingerprintHash){

	//igore the audio id (32 bits) and the time information (14 bits), leaving only 18 bits
	size_t number_of_results = 0;

	//printf("Query: %llu  (%d) \n",search_key,significant);

	olaf_fp_db_find(fp_matcher->db,queryFingerprintHash,0,fp_matcher->dbResults,fp_matcher->config->maxDBResults,&number_of_results);

	//fprintf(stderr,"Number of results: %zu \n",number_of_results);

	for(size_t i = 0 ; i < number_of_results ; i++){
		uint32_t referenceFingerprintT1 =  (uint32_t) (fp_matcher->dbResults[i] >> 32);
		uint32_t matchIdentifier = (uint32_t) fp_matcher->dbResults[i]; //last 32 bits are match identifier

		updateResults(fp_matcher,queryFingerprintT1,referenceFingerprintT1,matchIdentifier);
	}
}

int olaf_fp_matcher_match(Olaf_FP_Matcher * fp_matcher, struct extracted_fingerprints *  fingerprints ){
	
	int lastQueryFingerprintT1 =0;

	for(size_t i = 0 ; i < fingerprints->fingerprintIndex ; i++ ){
		struct fingerprint f = fingerprints->fingerprints[i];
		uint32_t hash = olaf_fp_extractor_hash(f);
		matchPrint(fp_matcher,f.timeIndex1,hash);
		
		lastQueryFingerprintT1 = f.timeIndex1;

		if(fp_matcher->config->includeOffByOneMatches){
			int originalt1 = f.timeIndex1;
			int originalt2 = f.timeIndex2;

			//to overcome time bin off by one misses
			f.timeIndex2 = originalt2 + 1;
			hash = olaf_fp_extractor_hash(f);
			matchPrint(fp_matcher,f.timeIndex1,hash);

			f.timeIndex2 = originalt2 - 1;
			hash = olaf_fp_extractor_hash(f);
			matchPrint(fp_matcher,f.timeIndex1,hash);

			f.timeIndex1 = originalt1;
			f.timeIndex2 = originalt2;
		}
	}
	
	ageResults(fp_matcher,lastQueryFingerprintT1);

	//make room for new fingerprints in the shared struct!
	fingerprints->fingerprintIndex=0;

	//report matches
	int maxMatchScore = 0;
	for(int i = 0 ; i < fp_matcher->config->maxResults ; i++){
		if(fp_matcher->results[i].matchCount >= fp_matcher->config->minMatchCount && fp_matcher->results[i].toPrint){
			float millisecondsPerBlock = 32.0;
			float timeDeltaF = millisecondsPerBlock * abs(fp_matcher->results[i].queryFingerprintT1 - fp_matcher->results[i].referenceFingerprintT1);
			float queryTime =   millisecondsPerBlock * fp_matcher->results[i].queryFingerprintT1;

			float referenceStart =  fp_matcher->results[i].firstReferenceFingerprintT1 * millisecondsPerBlock / 1000.0;
			float referenceStop =  fp_matcher->results[i].lastReferenceFingerprintT1 * millisecondsPerBlock / 1000.0;

			float timeDeltaS =  timeDeltaF / 1000.0;
			float queryTimeS = queryTime / 1000.0;
			uint32_t matchIdentifier = fp_matcher->results[i].matchIdentifier;
			fprintf(stderr,"q_to_ref_time_delta: %.2f, q_time: %.2f, score: %d, match_id: %u, ref_start: %.2f, ref_stop: %.2f\n",timeDeltaS, queryTimeS, fp_matcher->results[i].matchCount,matchIdentifier,referenceStart,referenceStop);
			
			fp_matcher->results[i].toPrint=false;
		}
		maxMatchScore = max(maxMatchScore,fp_matcher->results[i].matchCount);
	}

	return maxMatchScore;
}

void olaf_fp_matcher_destroy(Olaf_FP_Matcher * fp_matcher){
	free(fp_matcher->results);

	free(fp_matcher->dbResults);

	//db needs to be freed elswhere!
	//free resources
	//olaf_fp_db_destroy(fp_matcher->db);

	free(fp_matcher);
}
