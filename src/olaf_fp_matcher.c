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

	//List with all results
	struct match_result * m_results;

	//the current size of the results found
	size_t m_results_size;

	//the current index in the array
	size_t m_results_index;

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

//Creates a new matcher 
Olaf_FP_Matcher * olaf_fp_matcher_new(Olaf_Config * config,Olaf_DB* db ){
	Olaf_FP_Matcher *fp_matcher = (Olaf_FP_Matcher*) malloc(sizeof(Olaf_FP_Matcher));

	fp_matcher->db = db;

	//The maximum number of results returned by the database
	//This is the number of times a 'hash collision' is allowed in the 
	//database
	fp_matcher->m_results_size =  config->maxDBCollisions;

	//The database results are integers which combine a time info and match id
	fp_matcher->db_results = (uint64_t *) malloc(fp_matcher->m_results_size * sizeof(uint64_t));

	fp_matcher->config = config;

	fp_matcher->result_hash_table = hash_table_new(uint64_t_hash,uint64_t_equal);

	fp_matcher->m_results = (struct match_result *) malloc( fp_matcher->m_results_size  * sizeof(struct match_result));

	fp_matcher->m_results_index = 0;

	return fp_matcher;
}

// The grow method is called when m_results is full.
// It does a number of things:
//
//   1 It creates more (double) space in the m_results array
//   2 It clears the hash table and creates a new one
//   3 Filters for relevant results relevant here means not too old and a match score of less than 5
//   4 Stores the relevant result in the new m_results array and hash table
//   5 Frees memory that is not used any more
// 
// This should leave the hash table and m_results array relatively empty and with more
// than enough space while limiting memory use. 
// 
// When the m_results is full, grow is called again.
void olaf_fp_matcher_m_results_grow(Olaf_FP_Matcher * fp_matcher,int queryFingerprintT1){

	//store a pointer to the previous table
	struct match_result * prev_m_results = fp_matcher->m_results;
	size_t prev_size = fp_matcher->m_results_size;

	//modify the size
	//printf("Grow all results to %lu  \n",2 * fp_matcher->m_results_size);
	fp_matcher->m_results_size = 2 * fp_matcher->m_results_size;

	//allocate new memory
	fp_matcher->m_results = calloc( fp_matcher->m_results_size, sizeof(struct match_result));

	if (fp_matcher->m_results == NULL){
		fprintf(stderr,"Failed to allocate memory to grow all results array to %zu elements ",fp_matcher->m_results_size);
		exit(-5145);
	}

	//printf("Hash table size before grow %d \n",hash_table_num_entries(fp_matcher->result_hash_table));
	//free the hash table and recreate it with only relevant matches
	hash_table_free(fp_matcher->result_hash_table);

	//create a new hash table
	fp_matcher->result_hash_table = hash_table_new(uint64_t_hash,uint64_t_equal);

	//copy only results that are not too old or highly ranked
	fp_matcher->m_results_index = 0;
	for(size_t prev_index = 0 ; prev_index < prev_size; prev_index++){

		int age = queryFingerprintT1 - prev_m_results[prev_index].queryFingerprintT1;
		int match_count = prev_m_results[prev_index].matchCount;

		bool too_old = age >  fp_matcher->config->maxResultAge;
		bool too_popular = match_count >= fp_matcher->config->minMatchCount;
		if(!too_old && !too_popular){
			fp_matcher->m_results[fp_matcher->m_results_index]=prev_m_results[prev_index];

			//store the match in the hash table
			hash_table_insert(fp_matcher->result_hash_table, &fp_matcher->m_results[fp_matcher->m_results_index].result_hash_table_key, &fp_matcher->m_results[fp_matcher->m_results_index]);

			fp_matcher->m_results_index++;
		}
	}

	//free the previous array
	free(prev_m_results);

	//printf("Hash table size after grow %d \n",hash_table_num_entries(fp_matcher->result_hash_table));
}

// Counts matches for each hash hit and puts them in a hash table.
// A match_id and time difference are keys in the hash table, the value
// is a match_result struct pointer.
//
// This method should be fast since a single fingerprint hash could 
// return a thousand hits (collisons) from a large database
// 
void olaf_fp_matcher_tally_results(Olaf_FP_Matcher * fp_matcher,int queryFingerprintT1,int referenceFingerprintT1,uint32_t matchIdentifier){
	
	int timeDiff = queryFingerprintT1 - referenceFingerprintT1;

	//The time difference is expected to remain equal for a real match
	//The time difference to a certain match should remain equal
	uint64_t diff_part = ((uint64_t) timeDiff) << 32;
	uint64_t match_part = (uint64_t) matchIdentifier;

	uint64_t result_hash_table_key = diff_part + match_part;
	
	struct match_result * match = hash_table_lookup(fp_matcher->result_hash_table,&result_hash_table_key);

	if(match!=NULL){
		//Update match when found
		match->referenceFingerprintT1 = referenceFingerprintT1;
		match->queryFingerprintT1 = queryFingerprintT1;
		match->matchCount = match->matchCount + 1;
		match->firstReferenceFingerprintT1 = min(referenceFingerprintT1,match->firstReferenceFingerprintT1);
		match->lastReferenceFingerprintT1 = max(referenceFingerprintT1,match->lastReferenceFingerprintT1);

		//printf("UPDATE  %llu hash table size: %d  match_count: %d  %llu index \n",result_hash_table_key,hash_table_num_entries(fp_matcher->result_hash_table),match->matchCount,fp_matcher->m_results_index);
	}else{
		//Create new hashtable entry if not found
		size_t i = fp_matcher->m_results_index;

		fp_matcher->m_results[i].referenceFingerprintT1 = referenceFingerprintT1;
		fp_matcher->m_results[i].firstReferenceFingerprintT1 = referenceFingerprintT1;
		fp_matcher->m_results[i].lastReferenceFingerprintT1 = referenceFingerprintT1;
		fp_matcher->m_results[i].queryFingerprintT1 = queryFingerprintT1;
		fp_matcher->m_results[i].matchCount = 1;
		fp_matcher->m_results[i].matchIdentifier = matchIdentifier;
		fp_matcher->m_results[i].result_hash_table_key = result_hash_table_key;
	
		//printf("INSERT  %llu hash table size: %d \n",result_hash_table_key,hash_table_num_entries(fp_matcher->result_hash_table));

		hash_table_insert(fp_matcher->result_hash_table, &fp_matcher->m_results[i].result_hash_table_key, &fp_matcher->m_results[i]);

		fp_matcher->m_results_index++;

		//if the table is full we do some housekeeping
		if(fp_matcher->m_results_size == fp_matcher->m_results_index){
			olaf_fp_matcher_m_results_grow(fp_matcher,queryFingerprintT1);
		}
	}
}

//Match a single fingerprint with the database
void olaf_fp_matcher_match_single_fingerprint(Olaf_FP_Matcher * fp_matcher,uint32_t queryFingerprintT1,uint64_t queryFingerprintHash){

	int range = fp_matcher->config->searchRange;
	size_t number_of_results = olaf_db_find(fp_matcher->db,queryFingerprintHash-range,queryFingerprintHash+range,fp_matcher->db_results,fp_matcher->config->maxDBCollisions);

	//fprintf(stderr,"Number of results: %zu \n",number_of_results);

	for(size_t i = 0 ; i < number_of_results ; i++){
		//The 32 most significant bits represent ref t1
		uint32_t referenceFingerprintT1 =  (uint32_t) (fp_matcher->db_results[i] >> 32);
		//The last 32 bits represent the match identifier
		uint32_t matchIdentifier = (uint32_t) fp_matcher->db_results[i]; 

		//fprintf(stderr,"audio id: %u ref t1 %u \n",matchIdentifier,referenceFingerprintT1);

		olaf_fp_matcher_tally_results(fp_matcher,queryFingerprintT1,referenceFingerprintT1,matchIdentifier);
	}
}

void olaf_fp_matcher_match(Olaf_FP_Matcher * fp_matcher, struct extracted_fingerprints *  fingerprints ){
	
	for(size_t i = 0 ; i < fingerprints->fingerprintIndex ; i++ ){
		struct fingerprint f = fingerprints->fingerprints[i];
		uint64_t hash = olaf_fp_extractor_hash(f);

		
		olaf_fp_matcher_match_single_fingerprint(fp_matcher,f.timeIndex1,hash);
 
		if(fp_matcher->config->includeOffByOneMatches){
			int originalt1 = f.timeIndex1;
			int originalt2 = f.timeIndex2;

			//to overcome time bin off by one misses
			f.timeIndex2 = originalt2 + 1;
			hash = olaf_fp_extractor_hash(f);
			olaf_fp_matcher_match_single_fingerprint(fp_matcher,f.timeIndex1,hash);

			f.timeIndex2 = originalt2 - 1;
			hash = olaf_fp_extractor_hash(f);
			olaf_fp_matcher_match_single_fingerprint(fp_matcher,f.timeIndex1,hash);

			f.timeIndex1 = originalt1;
			f.timeIndex2 = originalt2;
		}
	}

	//make room for new fingerprints in the shared struct!
	fingerprints->fingerprintIndex=0;
}

//for use with qsort: a comparator that sorts result structs by match count
//Highest count first!
int olaf_fp_sort_results_by_match_count(const void * a, const void * b) {
	struct match_result * aResult = (struct match_result*)a;
	struct match_result * bResult = (struct match_result*)b;

	//first sort by match count from high to Low
	int diff = (bResult->matchCount - aResult->matchCount);

	return diff;
}

void olaf_fp_matcher_print_header(){
	//matchIdentifier,match->matchCount, timeDeltaS,referenceStart,referenceStop,queryTimeS
	printf("match id, match count (#), q to ref time delta (s), ref start (s), ref stop (s), query time (s)\n");
}

//Print the final results: sort the m_results array and print
void olaf_fp_matcher_print_results(Olaf_FP_Matcher * fp_matcher){
	
	//sort by match count, most matches first
	qsort(fp_matcher->m_results, fp_matcher->m_results_index, sizeof(struct match_result), olaf_fp_sort_results_by_match_count);

	//print the result from high to low
	for(size_t i = 0 ; i < fp_matcher->m_results_index ; i++){
		struct match_result * match = &fp_matcher->m_results[i];

		if(match->matchCount >= fp_matcher->config->minMatchCount){
			float secondsPerBlock = ((float) fp_matcher->config->audioStepSize) / ((float) fp_matcher->config->audioSampleRate);
			float timeDelta = secondsPerBlock * (match->queryFingerprintT1 - match->referenceFingerprintT1);
			float queryTime =   secondsPerBlock * match->queryFingerprintT1;

			float referenceStart =  match->firstReferenceFingerprintT1 * secondsPerBlock;
			float referenceStop =  match->lastReferenceFingerprintT1 * secondsPerBlock;
			
			uint32_t matchIdentifier = match->matchIdentifier;

			Olaf_Resource_Meta_data meta_data;
			olaf_db_find_meta_data(fp_matcher->db,&matchIdentifier,&meta_data);

			printf("%u, %s, %d, %.2f, %.2f, %.2f, %.2f\n",matchIdentifier,meta_data.path,match->matchCount, timeDelta,referenceStart,referenceStop,queryTime);
		} else {

			//Ignore matches with a small score
			//for performance reasons
			break;
		}
	}

	//report empty results if not results are found
	if(fp_matcher->m_results_index == 0 || fp_matcher->m_results[0].matchCount < fp_matcher->config->minMatchCount ){
		printf("%u, %d, %.2f, %.2f, %.2f, %.2f\n",0,0, 0.0,0.0,0.0,0.0);
	}
}

void olaf_fp_matcher_destroy(Olaf_FP_Matcher * fp_matcher){

	free(fp_matcher->m_results);

	free(fp_matcher->result_hash_table);

	free(fp_matcher->db_results);

	//db needs to be freed elswhere!
	//free resources
	//olaf_fp_db_destroy(fp_matcher->db);

	free(fp_matcher);
}
