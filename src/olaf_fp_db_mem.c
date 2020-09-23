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
#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include <stdint.h>

#include "olaf_fp_db.h"

#include "olaf_fp_ref_mem.h"

// The 'database' is a serialized sorted array of uint64_t elements
// Of the 64 bits:
// - The 32 most significant bits are a hash
// - The next 32 bits a time stamp 
// - Only a single song is currently supported for the memory store. So no song ID is stored.
//
// About 13k fingerprints are used for a 4min song
// 13k * 64bit =  100kB, with 20GB memory about 200k songs can be stored

struct Olaf_FP_DB{
	const uint64_t * ref_fp;
	size_t ref_fp_length;
};


//create a new databas
Olaf_FP_DB * olaf_fp_db_new(const char * db_file_folder,bool readonly){
	//prevent unused params
	(void)(db_file_folder);
	(void)(readonly);

	Olaf_FP_DB *olaf_fp_db = (Olaf_FP_DB*) malloc(sizeof(Olaf_FP_DB));

	//Point to the const data in the header
	olaf_fp_db->ref_fp = fp_ref_mem;
	olaf_fp_db->ref_fp_length = fp_ref_mem_length;

	return olaf_fp_db;
}


void olaf_fp_db_store(Olaf_FP_DB * olaf_fp_db, uint32_t * keys, uint64_t * values, size_t size){
	(void)(olaf_fp_db);
	(void)(keys);
	(void)(values);
	(void)(size);

	fprintf(stderr,"Not  implemented");
	exit(-10);
}

void olaf_fp_db_store_bulk(Olaf_FP_DB *, uint32_t * keys, uint64_t * values, size_t size){
	(void)(olaf_fp_db);
	(void)(keys);
	(void)(values);
	(void)(size);

	fprintf(stderr,"Not  implemented");
	exit(-10);
}

//For the binary search the timespans (last 32 bits) are ignored
int compare(const void * a, const void * b) {
	//the comparator ignores the last 32 bits, the timestamp
	return ( (*(uint64_t*)a>>32) - (*(uint64_t*)b>>32) );
}

//find a list of elements in the memory store
//only take into account the x most significant bits
void olaf_fp_db_find(Olaf_FP_DB * olaf_fp_db,uint32_t key,int bits_to_ignore,uint64_t * results, size_t results_size, size_t * number_of_results){
	
	uint32_t start_key = (key>>bits_to_ignore)<<bits_to_ignore;

	//to prevent overflow use a 64 bit value
	uint32_t v = 1;

	uint32_t stop_key = start_key | ((v<<bits_to_ignore)-1);

	size_t results_index = 0;

	uint64_t result_match_id = 666;

	//to use the bsearch method, a uint64_t key is needed
	uint64_t largeKey = key;

	largeKey = largeKey << 32;

	uint64_t * match = (uint64_t*) bsearch(&largeKey, olaf_fp_db->ref_fp, olaf_fp_db->ref_fp_length, sizeof (uint64_t), compare);

	if(match !=NULL){

		//It is possible that multiple hashes collide: only the timestamp is different then
		//If there is a collision the match position is randomly between (or on) the first and last end of the (ordered) list of collisions
		//To find all matches the matches before and after are checked whether they also match (or not)

		size_t index = match - olaf_fp_db->ref_fp;
		int result_index = 0;
		//on and before the match
		for(size_t i = index ; i < olaf_fp_db->ref_fp_length && (olaf_fp_db->ref_fp[i] >> 32) >= start_key && (olaf_fp_db->ref_fp[i] >> 32) <= stop_key ;i--){
						
			if(results_index<results_size){
				uint32_t fp_time = (uint32_t) (olaf_fp_db->ref_fp[i]);
				uint64_t result_fp_time = fp_time;

				results[result_index]=(result_fp_time << 32) + result_match_id;
				result_index++;
			}else{
				fprintf(stderr, "Ignored result, max number of results %zu reached\n",results_size);
			}	
		}
		//after the match
		for(size_t i = index + 1 ; i < olaf_fp_db->ref_fp_length && (olaf_fp_db->ref_fp[i] >> 32) >= start_key && (olaf_fp_db->ref_fp[i] >> 32) <= stop_key ;i++){

			if(results_index<results_size){
				uint32_t fp_time = (uint32_t) (olaf_fp_db->ref_fp[i]);
				uint64_t result_fp_time = fp_time;

				results[result_index]=(result_fp_time << 32) + result_match_id;
				result_index++;
			}else{
				fprintf(stderr, "Ignored result, max number of results %zu reached\n",results_size);
			}			
		}

		*number_of_results = result_index;
	}else{
		//printf("Not found %llu, start %llu, stop %llu, bits %d \n",key,start_key,stop_key,bits_to_ignore);
		*number_of_results = 0;
	}
}

bool olaf_fp_db_find_single(Olaf_FP_DB * olaf_fp_db,uint32_t key,int bits_to_ignore){

	uint32_t start_key = (key>>bits_to_ignore)<<bits_to_ignore;

	//to prevent overflow use a 64 bit value
	uint32_t v = 1;

	uint32_t stop_key = start_key | ((v<<bits_to_ignore)-1);

	//lin search, replace with binary search!
	for(size_t i = 0 ; i < olaf_fp_db->ref_fp_length ; i++){

		uint32_t fp_hash = (uint32_t) (olaf_fp_db->ref_fp[i]>>32);

		if(fp_hash < start_key){
			continue;
		}

		if(fp_hash > stop_key){
			break;
		}

		//hash between start and stop: found!
		return true;
	}

	return false;

}

//free memory resources and 
void olaf_fp_db_destroy(Olaf_FP_DB * olaf_fp_db){
	free(olaf_fp_db);
}

//print database statistics
void olaf_fp_db_stats(Olaf_FP_DB * olaf_fp_db){
	printf("Number of fingerprints in header file: %zu\n",olaf_fp_db->ref_fp_length);
}

//hash 
uint32_t olaf_fp_db_string_hash(const char *key, size_t len){
	(void)(key);
	(void)(len);
	fprintf(stderr,"Not implemented\n");
	exit(-10);
}
