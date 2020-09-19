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

#include "hash-table.h"
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

	//Ordered list of selected, best results
	//The list is ordered ascendingly according to 
	//match count first and then age (oldest first)
	struct match_result ** best_results;


	//list with all results meant to be reused at random
	//the length equals 20 x maxDBResults
	struct match_result * all_results;

	//A hash table with match_results
	//key is a combination of match_id and time diff
	HashTable *result_hash_table;

	//the database to use
	Olaf_FP_DB * db;

	//the configuration of Olaf
	Olaf_Config * config;

	//a list of results returns by the database
	//limited to a configured maxDBResults
	uint64_t * db_results;
};

unsigned int uint64_t_hash(void *vlocation){
	uint64_t *location;

	location = (uint64_t *) vlocation;

	uint32_t low_bits = (uint32_t) *location;
	uint32_t high_bits = (uint32_t) (*location >> 32);

	//simply or them together
	return (unsigned int) (low_bits ^ high_bits);
}

int uint64_t_equal(void *vlocation1, void *vlocation2){
	uint64_t *location1;
	uint64_t *location2;

	location1 = (uint64_t *) vlocation1;
	location2 = (uint64_t *) vlocation2;

	return *location1 == *location2;
}


Olaf_FP_Matcher * olaf_fp_matcher_new(Olaf_Config * config,Olaf_FP_DB* db ){
	Olaf_FP_Matcher *fp_matcher = (Olaf_FP_Matcher*) malloc(sizeof(Olaf_FP_Matcher));

	fp_matcher->db = db;

	fp_matcher->db_results = (uint64_t *) malloc(config->maxDBResults * sizeof(uint64_t));

	fp_matcher->config = config;

	fp_matcher->result_hash_table = hash_table_new(uint64_t_hash,uint64_t_equal);

	fp_matcher->all_results = (struct match_result *) malloc(100 * config->maxDBResults  * sizeof(struct match_result));

	fp_matcher->best_results = (struct match_result **) malloc(config->maxResults  * sizeof(struct match_result *));



	for(int i = 0; i < 100 * config->maxDBResults;i++){
		fp_matcher->all_results[i].matchCount=0;
		fp_matcher->all_results[i].referenceFingerprintT1 = 0;
		fp_matcher->all_results[i].firstReferenceFingerprintT1 = 0;
		fp_matcher->all_results[i].lastReferenceFingerprintT1 = 0;
		fp_matcher->all_results[i].queryFingerprintT1 = 0;
		fp_matcher->all_results[i].matchCount = 0;
		fp_matcher->all_results[i].timeDiff=0;
		fp_matcher->all_results[i].matchIdentifier = 0;
		fp_matcher->all_results[i].toPrint = false;
	}

	for(int i = 0; i < config->maxResults;i++){
		fp_matcher->best_results[i] = NULL;
	}

	puts("Fp matcher new");

	return fp_matcher;
}

int compareResults (const void * a, const void * b) {
	struct match_result * aResult = (struct match_result*)a;
	struct match_result * bResult = (struct match_result*)b;

	//first sort by match count from low to high
	int diff = (aResult->matchCount - bResult->matchCount);

	//if the match count is equal, sort by age
	// oldest (lowest t1) first
	if(diff == 0){
		diff = (aResult->queryFingerprintT1 - bResult->queryFingerprintT1);
	}

	return diff;
}

void updateResults(Olaf_FP_Matcher * fp_matcher,int queryFingerprintT1,int referenceFingerprintT1,uint32_t matchIdentifier){
	
	int timeDiff = queryFingerprintT1 - referenceFingerprintT1;

	//The time difference is expected to remain equal for a real match
	//The time difference to a certain match should remain equal
	uint64_t diff_part = (uint64_t) timeDiff;
	uint64_t match_part = ((uint64_t) matchIdentifier) << 32;
	uint64_t result_hash_table_key = diff_part + match_part;
	
	struct match_result * match = hash_table_lookup(fp_matcher->result_hash_table,&result_hash_table_key);

	if(match!=NULL){

		match->referenceFingerprintT1 = referenceFingerprintT1;
		match->queryFingerprintT1 = queryFingerprintT1;
		match->matchCount = match->matchCount + 1;
		match->toPrint = true;

		match->firstReferenceFingerprintT1 = min(referenceFingerprintT1,match->firstReferenceFingerprintT1);
		match->lastReferenceFingerprintT1 = max(referenceFingerprintT1,match->lastReferenceFingerprintT1);

		//printf("Match found  %lu hash table size: %d \n",result_hash_table_key,hash_table_num_entries(fp_matcher->result_hash_table));

		//add to best matches
		if(match->matchCount!=2){
			fp_matcher->best_results[0]=match;
		}
		

		//sort to keep  order:  lowest match count first
		qsort(fp_matcher->best_results, fp_matcher->config->maxResults, sizeof(struct match_result *), compareResults);
	}else{
		//add to the hash map

		int randomStartPlace = rand() % (80 * fp_matcher->config->maxDBResults);

		for(int i = randomStartPlace; i < 100 * fp_matcher->config->maxDBResults;i++){
			if(fp_matcher->all_results[i].matchCount==0){
				fp_matcher->all_results[i].referenceFingerprintT1 = referenceFingerprintT1;
				fp_matcher->all_results[i].firstReferenceFingerprintT1 = referenceFingerprintT1;
				fp_matcher->all_results[i].lastReferenceFingerprintT1 = referenceFingerprintT1;
				fp_matcher->all_results[i].queryFingerprintT1 = queryFingerprintT1;
				fp_matcher->all_results[i].matchCount = 1;
				fp_matcher->all_results[i].timeDiff=timeDiff;
				fp_matcher->all_results[i].matchIdentifier = matchIdentifier;
				fp_matcher->all_results[i].toPrint = true;

				//printf("Insert  %lu hash table size: %d \n",result_hash_table_key,hash_table_num_entries(fp_matcher->result_hash_table));


				hash_table_insert(fp_matcher->result_hash_table, &result_hash_table_key, &fp_matcher->all_results[i]);
				break;
			}else{
				//check and mark if needed
				int age = queryFingerprintT1 - fp_matcher->all_results[i].queryFingerprintT1;

				if(age >  fp_matcher->config->maxResultAge){
					diff_part = (uint64_t) fp_matcher->all_results[i].timeDiff;
					match_part = ((uint64_t) fp_matcher->all_results[i].matchIdentifier) << 32;
					uint64_t remove_hash_table_key = diff_part + match_part;

					//remove from hash table
					hash_table_remove(fp_matcher->result_hash_table, &remove_hash_table_key);

					printf("Removed from hash table %lu \n",remove_hash_table_key);
					//reset data fields for reuse
					fp_matcher->all_results[i].timeDiff = 0;
					fp_matcher->all_results[i].queryFingerprintT1 = 0;
					fp_matcher->all_results[i].referenceFingerprintT1 = 0;
					fp_matcher->all_results[i].firstReferenceFingerprintT1 = 0;
					fp_matcher->all_results[i].lastReferenceFingerprintT1 = 0;
					fp_matcher->all_results[i].matchCount = 0;
					fp_matcher->all_results[i].matchIdentifier = 0;
					fp_matcher->all_results[i].toPrint = false;
				}
			}
		}
	}
}


void ageResults(Olaf_FP_Matcher * fp_matcher,int lastQueryFingerprintT1){


	for(int i = 0 ; i < fp_matcher->config->maxResults ; i++){
		if(fp_matcher->best_results[i] == NULL){
			continue;
		}
		int age = lastQueryFingerprintT1 - fp_matcher->best_results[i]->queryFingerprintT1;
		
		//Remove matches that are too old (age over max)
		printf("Age:  %d , last: %d, current %d \n",age,lastQueryFingerprintT1,fp_matcher->best_results[i]->queryFingerprintT1);
		if(fp_matcher->config->maxResultAge < age){

			uint64_t diff_part = (uint64_t) fp_matcher->best_results[i]->timeDiff;
			uint64_t match_part = ((uint64_t) fp_matcher->best_results[i]->matchIdentifier) << 32;
			uint64_t remove_hash_table_key = diff_part + match_part;

			//remove from hash table
			hash_table_remove(fp_matcher->result_hash_table, &remove_hash_table_key);

			printf("Removed from hash table %lu \n",remove_hash_table_key);

			//If the result is the current max, reset the indicator and the currentMatchScore
			fp_matcher->best_results[i]->timeDiff = 0;
			fp_matcher->best_results[i]->queryFingerprintT1 = 0;
			fp_matcher->best_results[i]->referenceFingerprintT1 = 0;
			fp_matcher->best_results[i]->firstReferenceFingerprintT1 = 0;
			fp_matcher->best_results[i]->lastReferenceFingerprintT1 = 0;
			fp_matcher->best_results[i]->matchCount = 0;
			fp_matcher->best_results[i]->matchIdentifier = 0;
			fp_matcher->best_results[i]->toPrint = false;

			fp_matcher->best_results[i]=NULL;
		}
	}
}

void matchPrint(Olaf_FP_Matcher * fp_matcher,uint32_t queryFingerprintT1,uint32_t queryFingerprintHash){

	//igore the audio id (32 bits) and the time information (14 bits), leaving only 18 bits
	size_t number_of_results = 0;

	//printf("Query: %llu  (%d) \n",search_key,significant);

	olaf_fp_db_find(fp_matcher->db,queryFingerprintHash,0,fp_matcher->db_results,fp_matcher->config->maxDBResults,&number_of_results);

	fprintf(stdout,"Number of results: %zu \n",number_of_results);

	for(size_t i = 0 ; i < number_of_results ; i++){
		uint32_t referenceFingerprintT1 =  (uint32_t) (fp_matcher->db_results[i] >> 32);
		uint32_t matchIdentifier = (uint32_t) fp_matcher->db_results[i]; //last 32 bits are match identifier

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
		if(fp_matcher->best_results[i] == NULL){
			continue;
		}
		if(fp_matcher->best_results[i]->matchCount >= fp_matcher->config->minMatchCount && fp_matcher->best_results[i]->toPrint){
			float millisecondsPerBlock = 32.0;
			float timeDeltaF = millisecondsPerBlock * abs(fp_matcher->best_results[i]->queryFingerprintT1 - fp_matcher->best_results[i]->referenceFingerprintT1);
			float queryTime =   millisecondsPerBlock * fp_matcher->best_results[i]->queryFingerprintT1;

			float referenceStart =  fp_matcher->best_results[i]->firstReferenceFingerprintT1 * millisecondsPerBlock / 1000.0;
			float referenceStop =  fp_matcher->best_results[i]->lastReferenceFingerprintT1 * millisecondsPerBlock / 1000.0;

			float timeDeltaS =  timeDeltaF / 1000.0;
			float queryTimeS = queryTime / 1000.0;
			uint32_t matchIdentifier = fp_matcher->best_results[i]->matchIdentifier;
			fprintf(stderr,"q_to_ref_time_delta: %.2f, q_time: %.2f, score: %d, match_id: %u, ref_start: %.2f, ref_stop: %.2f\n",timeDeltaS, queryTimeS, fp_matcher->best_results[i]->matchCount,matchIdentifier,referenceStart,referenceStop);
			
			fp_matcher->best_results[i]->toPrint=false;
		}
		maxMatchScore = max(maxMatchScore,fp_matcher->best_results[i]->matchCount);
	}

	return maxMatchScore;
}

void olaf_fp_matcher_destroy(Olaf_FP_Matcher * fp_matcher){
	free(fp_matcher->all_results);
	free(fp_matcher->best_results);

	free(fp_matcher->result_hash_table);

	free(fp_matcher->db_results);

	//db needs to be freed elswhere!
	//free resources
	//olaf_fp_db_destroy(fp_matcher->db);

	free(fp_matcher);
}
