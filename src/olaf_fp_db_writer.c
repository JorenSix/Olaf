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
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include "olaf_fp_db_writer.h"
#include "olaf_db.h"

struct Olaf_FP_DB_Writer{
	uint64_t keys[1<<12];
	uint64_t values[1<<12];

	int index;

	int threshold;

	Olaf_DB * db;

	uint32_t audio_file_identifier;
};


Olaf_FP_DB_Writer * olaf_fp_db_writer_new(Olaf_DB* db,uint32_t audio_file_identifier){
	Olaf_FP_DB_Writer *db_writer = malloc(sizeof(Olaf_FP_DB_Writer));

	db_writer->db = db;
	db_writer->threshold = 0.8 * (1<<12);
	db_writer->index=0;
	
	//printf("audio id: %u\n",audio_file_identifier);
	db_writer->audio_file_identifier = audio_file_identifier;
	return db_writer;
}

void olaf_fp_db_writer_store( Olaf_FP_DB_Writer * db_writer , struct extracted_fingerprints * fingerprints ){

	for(size_t i = 0 ; i < fingerprints->fingerprintIndex; i++){

		uint64_t key = olaf_fp_extractor_hash(fingerprints->fingerprints[i]);
		uint64_t fingerprint_t1 = fingerprints->fingerprints[i].timeIndex1;
		uint64_t fingerprint_id = db_writer->audio_file_identifier;

		db_writer->keys[db_writer->index] = key;
		db_writer->values[db_writer->index] = (fingerprint_t1<<32) + fingerprint_id;

		db_writer->index++;
	}

	fingerprints->fingerprintIndex = 0;
	
	if(db_writer->index > db_writer->threshold){
		olaf_db_store(db_writer->db,db_writer->keys,db_writer->values,db_writer->index);
		db_writer->index = 0;
	}
}

void olaf_fp_db_writer_delete( Olaf_FP_DB_Writer * db_writer , struct extracted_fingerprints * fingerprints ){
	for(size_t i = 0 ; i < fingerprints->fingerprintIndex; i++){

		uint64_t key = olaf_fp_extractor_hash(fingerprints->fingerprints[i]);
		uint64_t fingerprint_t1 = fingerprints->fingerprints[i].timeIndex1;
		uint64_t fingerprint_id = db_writer->audio_file_identifier;
		//uint32_t significant = hash_to_store>>46;

		//printf("Store: %llu = %llu + %u (%d) \n",hash_to_store,fingerprint_hash, db_writer->audio_file_identifier,significant);

		db_writer->keys[db_writer->index] = key;
		db_writer->values[db_writer->index] = (fingerprint_t1<<32) + fingerprint_id;

		db_writer->index++;
	}

	fingerprints->fingerprintIndex = 0;

	//printf("%s\n", "store" );
	//store if threshold is exceeded
	if(db_writer->index > db_writer->threshold){
		olaf_db_delete(db_writer->db,db_writer->keys,db_writer->values,db_writer->index);
		db_writer->index = 0;
	}
}


void olaf_fp_db_writer_destroy(Olaf_FP_DB_Writer * db_writer,bool store){
	
	//store or delete remaining hashes
	if(store)
		olaf_db_store(db_writer->db,db_writer->keys,db_writer->values,db_writer->index);
	else
		olaf_db_delete(db_writer->db,db_writer->keys,db_writer->values,db_writer->index);

	db_writer->index = 0;

	free(db_writer);
}
