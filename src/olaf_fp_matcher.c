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
#include <stdbool.h>
#include <inttypes.h>

#include "hash-table.h"
#include "olaf_fp_matcher.h"
#include "olaf_fp_extractor.h"
#include "olaf_db.h"

struct match_result{
	// The time of the matched reference fingerprint t1 
	int referenceFingerprintT1;

	//The time of the query fingerprint f1
	int queryFingerprintT1;

	//The first found match in the reference for this time difference
	//Storing the first and last match makes it possible to identify
	//the matched secion in the reference audio
	int firstReferenceFingerprintT1;

	//The last found match in the reference for this time difference
	int lastReferenceFingerprintT1;

	//The number of occurences with this exact time difference
	int matchCount;

	//the matching audio file
	uint32_t matchIdentifier;

	//the key used in the hash table
	uint64_t result_hash_table_key;
};

inline int max ( int a, int b ) { return a > b ? a : b; }
inline int min ( int a, int b ) { return a < b ? a : b; }

struct Olaf_FP_Matcher{

	//A hash table to quickly check whether a match_id and time diff
	//combination has already been encountered

	//The key is pointer to a combination of match_id and time diff 
	//    values pointers to match structs
	HashTable *result_hash_table;

	//The database to use
	Olaf_DB * db;

	//The configuration of Olaf
	Olaf_Config * config;

	//A list of results returns by the database
	//  limited to a configured maxDBCollisions
	uint64_t * db_results;

	Olaf_FP_Matcher_Result_Callback result_callback;


	int last_print_at;
};

//For the hash table use a 64 bit key mapped to 32 bits
unsigned int uint64_t_hash(void *vlocation){
	uint64_t *location;

	location = (uint64_t *) vlocation;

	uint32_t low_bits = (uint32_t) *location;
	uint32_t high_bits = (uint32_t) ((*location) >> 32);

	//simply or them together
	return (unsigned int) (low_bits ^ high_bits);
}

//Check whether two hash keys are equal
int uint64_t_equal(void *vlocation1, void *vlocation2){
	uint64_t *location1;
	uint64_t *location2;

	location1 = (uint64_t *) vlocation1;
	location2 = (uint64_t *) vlocation2;

	return *location1 == *location2;
}


//void olaf_hash_table_key_free_func(void *key){
	//NOOP, key is freed by value free func
	//
	//fprintf(stderr,"%llu free key\n", *((uint64_t *)key));
	//free(key);
//}

void olaf_hash_table_value_free_func(void *value){
	free(value);
}

//Creates a new matcher 
Olaf_FP_Matcher * olaf_fp_matcher_new(Olaf_Config * config,Olaf_DB* db,Olaf_FP_Matcher_Result_Callback callback ){
	Olaf_FP_Matcher *fp_matcher = (Olaf_FP_Matcher *) malloc(sizeof(Olaf_FP_Matcher));
	
	//The database results are integers which combine a time info and match id
	fp_matcher->db_results = (uint64_t *) calloc(config->maxDBCollisions , sizeof(uint64_t));
	fp_matcher->result_hash_table = hash_table_new(uint64_t_hash,uint64_t_equal);
	fp_matcher->last_print_at = 0;
	fp_matcher->config = config;
	fp_matcher->db = db;
	fp_matcher->result_callback = callback;

	hash_table_register_free_functions(fp_matcher->result_hash_table,NULL, olaf_hash_table_value_free_func);

	return fp_matcher;
}

// This iterates the hash table with matches and 
// removes old matches for streaming purposes reset all matches which are too old
void olaf_fp_matcher_remove_old_matches(Olaf_FP_Matcher * fp_matcher, int current_query_time ){
	
	//from seconds to the number of blocks 
	int max_age = (int) ((fp_matcher->config->keepMatchesFor  * fp_matcher->config->audioSampleRate) /  fp_matcher->config->audioStepSize);

	HashTableIterator iterator;
	HashTablePair pair;
	hash_table_iterate(fp_matcher->result_hash_table, &iterator);
	while (hash_table_iter_has_more(&iterator)) {
		pair = hash_table_iter_next(&iterator);
		struct match_result * match = (struct match_result *) pair.value;
		int age = current_query_time - match->queryFingerprintT1;
		bool too_old = age > max_age;
		if(too_old){
			hash_table_remove(fp_matcher->result_hash_table, pair.key);
			//printf("Match too old and removed. Current query time %d, match time %d, age %d, max age %d\n",current_query_time,match->queryFingerprintT1,age,max_age);
		}
	}
}

// Counts matches for each hash hit and puts them in a hash table.
// A match_id and time difference are keys in the hash table, the value
// is a match_result struct pointer.
//
// This method should be fast since a single fingerprint hash could 
// return a thousand hits (collisons) from a large database
// 
void olaf_fp_matcher_tally_results(Olaf_FP_Matcher * fp_matcher,int queryFingerprintT1,int referenceFingerprintT1,uint32_t matchIdentifier){
	
	int timeDiff = (queryFingerprintT1 - referenceFingerprintT1) >> 2;

	//The time difference is expected to remain equal for a real match
	//The time difference to a certain match should remain equal
	uint64_t diff_part = ((uint64_t) timeDiff) << 32;
	uint64_t match_part = (uint64_t) matchIdentifier;

	uint64_t result_hash_table_key = diff_part + match_part;
	
	struct match_result * match = (struct match_result *) hash_table_lookup(fp_matcher->result_hash_table,&result_hash_table_key);

	if(match!=NULL){
		//Update match when found
		match->referenceFingerprintT1 = referenceFingerprintT1;
		match->queryFingerprintT1 = queryFingerprintT1;
		match->matchCount = match->matchCount + 1;
		match->firstReferenceFingerprintT1 = min(referenceFingerprintT1,match->firstReferenceFingerprintT1);
		match->lastReferenceFingerprintT1 = max(referenceFingerprintT1,match->lastReferenceFingerprintT1);
		//if(match->matchCount>5) printf("UPDATE  %llu hash table size: %d  match_count: %d  %llu index, query time %d \n",result_hash_table_key,hash_table_num_entries(fp_matcher->result_hash_table),match->matchCount,fp_matcher->m_results_index,match->queryFingerprintT1);
	}else{
		//Create new hashtable entry if not found

		match = (struct match_result *) malloc(sizeof(struct match_result));

		match->referenceFingerprintT1 = referenceFingerprintT1;
		match->firstReferenceFingerprintT1 = referenceFingerprintT1;
		match->lastReferenceFingerprintT1 = referenceFingerprintT1;
		match->queryFingerprintT1 = queryFingerprintT1;
		match->matchCount = 1;
		match->matchIdentifier = matchIdentifier;
		match->result_hash_table_key = result_hash_table_key;
	
		//printf("INSERT  %llu hash table size: %d \n",result_hash_table_key,hash_table_num_entries(fp_matcher->result_hash_table));

		hash_table_insert(fp_matcher->result_hash_table, &match->result_hash_table_key, match);
	}
}

//Match a single fingerprint with the database
void olaf_fp_matcher_match_single_fingerprint(Olaf_FP_Matcher * fp_matcher,uint32_t queryFingerprintT1,uint64_t queryFingerprintHash){

	int range = fp_matcher->config->searchRange;
	size_t number_of_results = olaf_db_find(fp_matcher->db,queryFingerprintHash-range,queryFingerprintHash+range,fp_matcher->db_results,fp_matcher->config->maxDBCollisions);

	if(fp_matcher->config->verbose){
		fprintf(stderr,"Matched fp hash %" PRIu64 " with database at q t1 %u, search range %d.\n\tNumber of results: %zu \n\tMax num results: %zu \n",queryFingerprintHash,queryFingerprintT1,range,number_of_results,fp_matcher->config->maxDBCollisions);
	}
	
	if(number_of_results >= fp_matcher->config->maxDBCollisions){
		fprintf(stderr,"Expected less results for fp hash %" PRIu64 ", Number of results: %zu, search range %d, max: %zu \n",queryFingerprintHash,number_of_results,range,fp_matcher->config->maxDBCollisions);
	}

	for(size_t i = 0 ; i < number_of_results && i < fp_matcher->config->maxDBCollisions  ; i++){
		
		//The 32 most significant bits represent ref t1
		uint32_t referenceFingerprintT1 =  (uint32_t) (fp_matcher->db_results[i] >> 32);
		//The last 32 bits represent the match identifier
		uint32_t matchIdentifier = (uint32_t) fp_matcher->db_results[i]; 

		if(fp_matcher->config->verbose){
			int delta = (int) queryFingerprintT1 - (int) referenceFingerprintT1;
			fprintf(stderr,"\taudio id: %u\n\tref t1: %u \n\tdelta qt1-ft1: %d \n",matchIdentifier,referenceFingerprintT1,delta);
		}

		olaf_fp_matcher_tally_results(fp_matcher,queryFingerprintT1,referenceFingerprintT1,matchIdentifier);
	}
}

void olaf_fp_matcher_match(Olaf_FP_Matcher * fp_matcher, struct extracted_fingerprints *  fingerprints ){
	
	for(size_t i = 0 ; i < fingerprints->fingerprintIndex ; i++ ){
		struct fingerprint f = fingerprints->fingerprints[i];
		uint64_t hash = olaf_fp_extractor_hash(f);
		olaf_fp_matcher_match_single_fingerprint(fp_matcher,f.timeIndex1,hash);
	}
	
	if(fingerprints->fingerprintIndex > 0 && fp_matcher->config->printResultEvery != 0){
		int printResultEvery = (fp_matcher->config->printResultEvery *  fp_matcher->config->audioSampleRate ) /  fp_matcher->config->audioStepSize;
		int current_query_time = fingerprints->fingerprints[fingerprints->fingerprintIndex-1].timeIndex3;
		//printf("Current time: %d, Last print at: %d \n", current_query_time,fp_matcher->last_print_at );
		if( current_query_time - fp_matcher->last_print_at > printResultEvery){
			olaf_fp_matcher_callback_print_header();
			olaf_fp_matcher_print_results(fp_matcher);
			fp_matcher->last_print_at = current_query_time;
		}
	}

	//remove old matches.
	if( fingerprints->fingerprintIndex > 0 && fp_matcher->config->keepMatchesFor != 0 ){
		int current_query_time = fingerprints->fingerprints[fingerprints->fingerprintIndex-1].timeIndex3;
		olaf_fp_matcher_remove_old_matches(fp_matcher,current_query_time);
	}
	
	
	//make room for new fingerprints in the shared struct!
	fingerprints->fingerprintIndex=0;
}

//for use with qsort: a comparator that sorts result structs by match count
//Highest count first!
int olaf_fp_sort_results_by_match_count(const void * a, const void * b) {
	struct match_result * aResult = *(struct match_result**)a;
	struct match_result * bResult = *(struct match_result**)b;

	//first sort by match count from high to Low
	int diff = (bResult->matchCount - aResult->matchCount);

	return diff;
}

void olaf_fp_matcher_callback_print_header(void){
	printf("match count (#), q start (s) , q stop (s), ref path, ref ID, ref start (s), ref stop (s)\n");
}
void olaf_fp_matcher_callback_print_result(int matchCount, float queryStart, float queryStop, const char* path, uint32_t matchIdentifier, float referenceStart, float referenceStop) {
    printf("%d, %.2f, %.2f, %s, %u, %.2f, %.2f\n", matchCount, queryStart, queryStop, path, matchIdentifier, referenceStart, referenceStop);
}


//Print the final results: sort the m_results array and print
void olaf_fp_matcher_print_results(Olaf_FP_Matcher * fp_matcher){
	size_t match_results_index = 0;
	size_t match_results_max = fp_matcher->config->maxResults;
	struct match_result ** match_results = (struct match_result **) calloc(match_results_max, sizeof(struct match_result*));

	HashTableIterator iterator;
	HashTablePair pair;
	hash_table_iterate(fp_matcher->result_hash_table, &iterator);
	while (hash_table_iter_has_more(&iterator)) {
		pair = hash_table_iter_next(&iterator);
		struct match_result * match = (struct match_result *) pair.value;

		if(match->matchCount >= fp_matcher->config->minMatchCount){

			if(match_results_max == match_results_index){
				qsort(match_results, match_results_index, sizeof(struct match_result *), olaf_fp_sort_results_by_match_count);
		
				//replace the match with the lowes count with the current if it has a higher count
				int current_least = match_results[match_results_index-1]->matchCount;

			
				if(match->matchCount > current_least){
					match_results[match_results_index-1] = match;
				}
			}else{
				match_results[match_results_index] = match;
				match_results_index++;
			}
		}
	}

    

	if(match_results_index > 0){

		qsort(match_results, match_results_index, sizeof(struct match_result *), olaf_fp_sort_results_by_match_count);
	}

	//print the result from high to low
	for(size_t i = 0 ; i < match_results_index ; i++){
		struct match_result * match = match_results[i];
		float secondsPerBlock = ((float) fp_matcher->config->audioStepSize) / ((float) fp_matcher->config->audioSampleRate);
		float timeDelta = secondsPerBlock * (match->queryFingerprintT1 - match->referenceFingerprintT1);
		
		float referenceStart =  match->firstReferenceFingerprintT1 * secondsPerBlock;
		float referenceStop =  match->lastReferenceFingerprintT1 * secondsPerBlock;

		if((referenceStop - referenceStart) >=  fp_matcher->config->minMatchTimeDiff ){

			float queryStart =  match->firstReferenceFingerprintT1 * secondsPerBlock + timeDelta;
			float queryStop =  match->lastReferenceFingerprintT1 * secondsPerBlock  + timeDelta;
			
			uint32_t matchIdentifier = match->matchIdentifier;

			Olaf_Resource_Meta_data meta_data;
			olaf_db_find_meta_data(fp_matcher->db,&matchIdentifier,&meta_data);

			fp_matcher->result_callback(match->matchCount,queryStart,queryStop,meta_data.path,matchIdentifier,referenceStart,referenceStop);
		}
	}

	//report empty results if not results are found
	if(match_results_index == 0 ){
		//printf("%d, %.2f, %.2f, %s, %u, %.2f, %.2f\n",0,0.0,0.0,"",0,0.0,0.0);
		fp_matcher->result_callback(0,0,0,"",0,0,0);
	}

	free(match_results);
}



void olaf_fp_matcher_destroy(Olaf_FP_Matcher * fp_matcher){
	hash_table_free(fp_matcher->result_hash_table);
	free(fp_matcher->db_results);

	free(fp_matcher);
}
