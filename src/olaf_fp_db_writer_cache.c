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
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>


#include "olaf_fp_db_writer_cache.h"
#include "olaf_config.h"
#include "olaf_db.h"

struct Olaf_FP_DB_Writer_Cache{
	Olaf_DB * db; /**< Reference to the fingerprint database */
	Olaf_Config * config; /**< Reference to the Olaf configuration */

	const char* csv_filename; /**< Path to the CSV cache file */

	uint64_t fp_hashes[FP_ARRAY_SIZE]; /**< Cached fingerprint hash keys */
	uint64_t fp_values[FP_ARRAY_SIZE]; /**< Cached fingerprint hash values */
	size_t fp_index; /**< Current index into the fingerprint cache arrays */

	size_t fp_counter; /**< Total number of fingerprints processed */
	uint64_t last_fp_t1; /**< Timestamp of the last fingerprint t1 value */

	uint64_t audio_file_identifier; /**< Identifier of the current audio file */
	const char* audio_filename; /**< File name of the current audio file */
};




void olaf_fp_db_writer_cache_set_audio_file_info(Olaf_FP_DB_Writer_Cache *db_writer_cache, const char *audio_file_path, uint64_t audio_file_identifier){
	if(db_writer_cache->audio_filename != NULL){
		free((void*)db_writer_cache->audio_filename);
	}
	db_writer_cache->audio_filename = strdup(audio_file_path);
	db_writer_cache->audio_file_identifier = audio_file_identifier;
}

//parses new format:
//5113090338, 11997, 28, 13566.224609, 12024, 15, 4625.463379, 12031, 94, 13430.319336
//281260083, 11997, 28, 13566.224609, 12024, 15, 4625.463379, 12048, 19, 6334.749023
//1638900200, 12012, 381, 22.856133, 12032, 408, 24.121077, 12052, 382, 456.642639

int olaf_fp_db_writer_cache_parse_csv_line(Olaf_FP_DB_Writer_Cache * db_writer_cache,char *line) {

    int column_counter = 0;

    char *token = strtok(line, ",");
    while (token != NULL && column_counter < 2) {

    	//fp_hash (column 0)
    	if(column_counter == 0){
    		uint64_t hash = strtoull(token, NULL, 10);
    		db_writer_cache->fp_hashes[db_writer_cache->fp_index] = hash;
    	}

    	//fp t1 (column 1)
    	if(column_counter == 1){
    		uint64_t fingerprint_t = strtoull(token, NULL, 10);
    		db_writer_cache->last_fp_t1 = fingerprint_t;
			uint64_t fingerprint_id = db_writer_cache->audio_file_identifier;
    		db_writer_cache->fp_values[db_writer_cache->fp_index] = (fingerprint_t<<32) + fingerprint_id; 
    	}

        token = strtok(NULL, ",");

        column_counter ++;
    }

    db_writer_cache->fp_index++;
    db_writer_cache->fp_counter++;

    return column_counter;
}


void olaf_fp_db_writer_cache_read_csv_file(Olaf_FP_DB_Writer_Cache * db_writer_cache) {

    FILE *fp = fopen(db_writer_cache->csv_filename, "r");
    if (fp == NULL) {
        fprintf(stderr,"Failed to open file: %s\n", db_writer_cache->csv_filename);
        return;
    }

    char line[MAX_LINE_LEN];
    while (fgets(line, MAX_LINE_LEN, fp) != NULL) {
        olaf_fp_db_writer_cache_parse_csv_line(db_writer_cache,line);
        if(db_writer_cache->fp_index == FP_ARRAY_SIZE){
			olaf_db_store(db_writer_cache->db,db_writer_cache->fp_hashes,db_writer_cache->fp_values,db_writer_cache->fp_index);
			db_writer_cache->fp_index = 0;
		}
    }

    fclose(fp);

    //store all remaining fp's
    olaf_db_store(db_writer_cache->db,db_writer_cache->fp_hashes,db_writer_cache->fp_values,db_writer_cache->fp_index);
	db_writer_cache->fp_index = 0;    
}

Olaf_FP_DB_Writer_Cache * olaf_fp_db_writer_cache_new(Olaf_DB* db,Olaf_Config * config,const char *csv_filename){
	Olaf_FP_DB_Writer_Cache *db_writer_cache = (Olaf_FP_DB_Writer_Cache *) malloc(sizeof(Olaf_FP_DB_Writer_Cache));

	db_writer_cache->db = db;
	db_writer_cache->config = config;

	db_writer_cache->audio_file_identifier = 0;
	db_writer_cache->audio_filename = NULL;

	db_writer_cache->fp_index = 0;
	db_writer_cache->fp_counter = 0;

	db_writer_cache->csv_filename = csv_filename;

	return db_writer_cache;
}

void olaf_fp_db_writer_cache_store( Olaf_FP_DB_Writer_Cache * db_writer_cache){
	
	olaf_fp_db_writer_cache_read_csv_file(db_writer_cache);

	float secondsPerBlock = ((float) db_writer_cache->config->audioStepSize) / ((float) db_writer_cache->config->audioSampleRate);

	//approximate duration of audio file using the last t1
	float approximateDuration = db_writer_cache->last_fp_t1 * secondsPerBlock;
	//store meta data
    Olaf_Resource_Meta_data meta_data;
    strcpy(meta_data.path,db_writer_cache->audio_filename);
    //printf("Store meta data %s \n",meta_data.path);
	meta_data.duration = approximateDuration;	
	meta_data.fingerprints = db_writer_cache->fp_counter;
	uint32_t audio_identifier = (uint32_t) db_writer_cache->audio_file_identifier;
	olaf_db_store_meta_data(db_writer_cache->db,&audio_identifier,&meta_data);
}

void olaf_fp_db_writer_cache_destroy(Olaf_FP_DB_Writer_Cache * db_writer_cache){
	if(db_writer_cache->audio_filename !=NULL){
		free((void*)db_writer_cache->audio_filename);
	}
	//store or delete remaining hashes
	free(db_writer_cache);
}
