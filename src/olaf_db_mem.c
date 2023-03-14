// Olaf: Overly Lightweight Acoustic Fingerprinting
// Copyright (C) 2019-2023  Joren Six

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
#include <inttypes.h>
#include <string.h>

#include "olaf_db.h"
#include "olaf_fp_ref_mem.h"

// The 'database' is a serialized sorted array of uint64_t elements
// Of the 64 bits:
// - The 48 most significant bits are a hash
// - The next 16 bits are a time stamp 
// - Only a single song is currently supported for the memory store. So no identifier is stored.
//
// About 5k fingerprints are used for a 4min song
// 5k * 64bit =  40kB

struct Olaf_DB{
	const uint64_t * ref_fp;
	size_t ref_fp_length;
};

//create a new databas
Olaf_DB * olaf_db_new(const char * db_file_folder,bool readonly){
	//prevents unused params warning
	(void)(db_file_folder);
	(void)(readonly);

	Olaf_DB *olaf_db = (Olaf_DB *) malloc(sizeof(Olaf_DB));

	//Point to the const data in the header
	olaf_db->ref_fp = olaf_db_mem_fps;
	olaf_db->ref_fp_length = olaf_db_mem_fp_length;

	fprintf(stderr,"Mem DB for '%s', %.3fs duration, %zu fingerprints, %d identifier\n",olaf_db_mem_audio_path,olaf_db_mem_audio_duration,olaf_db_mem_fp_length,olaf_db_mem_audio_id);

	return olaf_db;
}

void olaf_db_store(Olaf_DB * olaf_db, uint64_t * keys, uint64_t * values, size_t size){
	(void)(olaf_db);
	(void)(keys);
	(void)(values);
	(void)(size);
}

void olaf_db_mem_unpack(uint64_t packed, uint64_t * hash, uint32_t * t){
	*hash = (packed >> 16);
	*t = (uint32_t)((uint16_t) packed) ; 
}

uint64_t olaf_db_mem_pack(uint64_t hash, uint32_t t){
	uint64_t packed = 0;
	packed = (hash<<16);
	packed += t;
	return packed;
}


//For the binary search, the timespans (last 16 bits) are ignored
int olaf_dp_packed_hash_compare(const void * a, const void * b) {
	//the comparator ignores the last 16 bits, the timestamp
	return ( (*(uint64_t*)a>>16) - (*(uint64_t*)b>>16) );
}

//find a list of elements in the memory store
size_t olaf_db_find(Olaf_DB * olaf_db,uint64_t start_key,uint64_t stop_key,uint64_t * results, size_t results_size){
	size_t number_of_results = 0;
	size_t results_index = 0;
	uint64_t result_match_id = 666;

	uint64_t * match = NULL;
	
	for(uint64_t current_key = start_key; current_key <= stop_key ; current_key++ ){
		//to use the bsearch method, a uint64_t key is needed
		uint64_t packed_key = olaf_db_mem_pack(current_key,0);
		//fprintf(stderr, "Start hash: %llu stop hash: %llu\n" ,packed_key, olaf_db_mem_pack(stop_key,0));
	
		match = (uint64_t*) bsearch(&packed_key, olaf_db->ref_fp, olaf_db->ref_fp_length, sizeof (uint64_t), olaf_dp_packed_hash_compare);
		//stop the search if a match if found.
		if(match !=NULL){
			//fprintf(stderr, "Found match for %llu (packed: %llu) matches (between start %llu and stop %llu) , match %llu \n",current_key,packed_key,start_key,stop_key, match);
			break;
		}
		 
	}
	 
	if(match !=NULL){
		//It is possible that multiple hashes collide: only the timestamp is different then
		//If there is a collision the match position is randomly between (or on) the first and last end of the (ordered) list of collisions
		//To find all matches the matches before and after are checked whether they also match (or not)

		size_t index = match - olaf_db->ref_fp;

		//on and before the match
		for(size_t i = index ; i >= 0  ;i--){
			uint64_t ref_hash;
			uint32_t ref_t;
			olaf_db_mem_unpack(olaf_db->ref_fp[i],&ref_hash,&ref_t);

			if(ref_hash >= start_key && ref_hash <= stop_key){
				if(results_index < results_size){
					uint64_t t = ref_t;
					results[results_index]=(t << 32) + result_match_id;
					results_index++;
				}else{
					fprintf(stderr, "Ignored result, max number of results %zu reached\n",results_size);
				}
			}else{
				break;
			}
		}
		
		//after the match
		for(size_t i = index + 1 ; i < olaf_db->ref_fp_length  ;i++){
			uint64_t ref_hash;
			uint32_t ref_t;
			olaf_db_mem_unpack(olaf_db->ref_fp[i],&ref_hash,&ref_t);

			if(ref_hash >= start_key && ref_hash <= stop_key){
				if(results_index<results_size){
					uint64_t t = ref_t;
					results[results_index]= (t << 32) + result_match_id;
					results_index++;
				}else{
					fprintf(stderr, "Ignored result, max number of results %zu reached\n",results_size);
				}			
			}else{
				break;
			}

		}
		number_of_results = results_index;
	}else{
		//printf("Not, start %llu, stop %llu \n",start_key,stop_key);
		number_of_results = 0;
	}
	return number_of_results;
}

bool olaf_db_find_single(Olaf_DB * olaf_db,uint64_t start_key,uint64_t stop_key){

	//lin search, replace with binary search!
	for(size_t i = 0 ; i < olaf_db->ref_fp_length ; i++){
		uint64_t ref_hash;
		uint32_t ref_t;
		olaf_db_mem_unpack(olaf_db->ref_fp[i],&ref_hash,&ref_t);

		if(ref_hash < start_key){
			continue;
		}

		if(ref_hash > stop_key){
			break;
		}

		//fprintf(stderr, "Found %llu is between %llu and %llu \n",ref_hash, start_key,stop_key);

		//hash between start and stop: found!
		return true;
	}

	//fprintf(stderr, "NOT found between %llu and %llu \n", start_key,stop_key);

	return false;
}

//free memory resources and 
void olaf_db_destroy(Olaf_DB * olaf_db){
	free(olaf_db);
}

//print database statistics
void olaf_db_stats(Olaf_DB * olaf_db,bool verbose){
	(void)(verbose);
	printf("Number of fingerprints in header file: %zu\n",olaf_db->ref_fp_length);
}

//hash 
uint32_t olaf_db_string_hash(const char *key, size_t len){
	(void)(key);
	(void)(len);
	return 666;
}


void olaf_db_store_meta_data(Olaf_DB * olaf_db, uint32_t * key, Olaf_Resource_Meta_data * value){

	//adds additional fields to the 'database' header file
	printf("\n/** The length of the fingerprint array */\n");
	printf("const size_t olaf_db_mem_fp_length      = %zu;\n",value->fingerprints);

	printf("\n/** The single audio identifier: only one item can be stored in the memory store. */\n");
	printf("const uint32_t olaf_db_mem_audio_id     = %u;\n",*key);

	printf("\n/** The path of the original audio file. */\n");
	printf("const char* olaf_db_mem_audio_path      = \"%s\";\n",value->path);

	printf("\n/** The duration, in seconds, of the original audio file. */\n");
	printf("const double olaf_db_mem_audio_duration = %f;\n",value->duration);

	(void)(olaf_db);
}

//search for meta data
void olaf_db_find_meta_data(Olaf_DB * olaf_db, uint32_t * key, Olaf_Resource_Meta_data * value){
	(void)(olaf_db);
	if(*key == olaf_db_mem_audio_id){
		value->duration = (float) olaf_db_mem_audio_duration;
		value->fingerprints = olaf_db_mem_fp_length;
		strcpy(value->path,olaf_db_mem_audio_path);
	}
}

//Delete meta data 
void olaf_db_delete_meta_data(Olaf_DB * olaf_db, uint32_t * key){
	(void)(olaf_db);
	(void)(key);
}

//Check if there is meta data for a key
bool olaf_db_has_meta_data(Olaf_DB * olaf_db, uint32_t * key){
	(void)(olaf_db);
	(void)(key);
	return false;
}

//Print meta database statistics
void olaf_db_stats_meta_data(Olaf_DB * olaf_db,bool verbose){
	(void)(olaf_db);
	(void)(verbose);
}
