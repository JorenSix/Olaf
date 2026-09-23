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

#include "olaf_fp_db_writer.h"
#include "olaf_db.h"

enum { OLAF_FP_DB_WRITER_CAPACITY = 1 << 12 };

struct Olaf_FP_DB_Writer{
	uint64_t keys[OLAF_FP_DB_WRITER_CAPACITY]; /**< Buffered fingerprint hashes */
	uint64_t values[OLAF_FP_DB_WRITER_CAPACITY]; /**< Buffered timestamps and identifiers */
	size_t index; /**< Number of populated entries */
	Olaf_DB * db; /**< Borrowed; must outlive this writer */
	uint32_t audio_file_identifier;
};

Olaf_FP_DB_Writer * olaf_fp_db_writer_new(Olaf_DB* db,uint32_t audio_file_identifier){
	Olaf_FP_DB_Writer *db_writer = (Olaf_FP_DB_Writer *) malloc(sizeof(Olaf_FP_DB_Writer));
	db_writer->db = db;
	db_writer->index = 0;
	db_writer->audio_file_identifier = audio_file_identifier;
	return db_writer;
}

static void olaf_fp_db_writer_flush(Olaf_FP_DB_Writer * db_writer,bool store){
	if(db_writer->index == 0) return;
	if(store)
		olaf_db_store(db_writer->db,db_writer->keys,db_writer->values,db_writer->index);
	else
		olaf_db_delete(db_writer->db,db_writer->keys,db_writer->values,db_writer->index);
	db_writer->index = 0;
}

//A writer is used for either store or delete throughout its lifetime.
static void olaf_fp_db_writer_append(Olaf_FP_DB_Writer * db_writer,struct extracted_fingerprints * fingerprints,bool store){
	for(size_t i = 0; i < fingerprints->fingerprintIndex; i++){
		//Check before each append: a caller's batch may exceed our capacity.
		if(db_writer->index == OLAF_FP_DB_WRITER_CAPACITY)
			olaf_fp_db_writer_flush(db_writer,store);

		uint64_t key = olaf_fp_extractor_hash(fingerprints->fingerprints[i]);
		uint64_t fingerprint_t1 = fingerprints->fingerprints[i].timeIndex1;
		db_writer->keys[db_writer->index] = key;
		db_writer->values[db_writer->index] = (fingerprint_t1 << 32) + db_writer->audio_file_identifier;
		db_writer->index++;
	}
	fingerprints->fingerprintIndex = 0;
}

void olaf_fp_db_writer_store(Olaf_FP_DB_Writer * db_writer,struct extracted_fingerprints * fingerprints){
	olaf_fp_db_writer_append(db_writer,fingerprints,true);
}

void olaf_fp_db_writer_delete(Olaf_FP_DB_Writer * db_writer,struct extracted_fingerprints * fingerprints){
	olaf_fp_db_writer_append(db_writer,fingerprints,false);
}

void olaf_fp_db_writer_destroy(Olaf_FP_DB_Writer * db_writer,bool store){
	olaf_fp_db_writer_flush(db_writer,store);
	free(db_writer);
}
