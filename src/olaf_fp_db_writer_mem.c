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

#include "olaf_fp_db_writer.h"
#include "olaf_fp_extractor.h"

int fp_hash_compare(const void * a, const void * b) {
	uint64_t c = *(uint64_t*)a;
	uint64_t d = *(uint64_t*)b;

	if(c>d){
		return 1;
	}else if (c<d) {
		return -1;
	}else{
		return 0;
	}
}

struct Olaf_FP_DB_Writer{
	uint64_t* hashes;
	size_t hashes_size;
	size_t index;
};


Olaf_FP_DB_Writer * olaf_fp_db_writer_new(Olaf_DB* db,uint32_t audio_file_identifier){
	(void)(db);
	(void)(audio_file_identifier);

	Olaf_FP_DB_Writer *db_writer = (Olaf_FP_DB_Writer *) malloc(sizeof(Olaf_FP_DB_Writer));
	db_writer->hashes_size = 100000;
	db_writer->hashes = (uint64_t *) calloc(sizeof(uint64_t),db_writer->hashes_size);

	db_writer->index=0;
	
	return db_writer;
}

void olaf_fp_db_writer_store( Olaf_FP_DB_Writer * db_writer , struct extracted_fingerprints * fingerprints ){

	for(size_t i = 0 ; i < fingerprints->fingerprintIndex; i++){
		uint64_t fp_hash = olaf_fp_extractor_hash(fingerprints->fingerprints[i]);
		uint64_t fp_time = (uint16_t) fingerprints->fingerprints[i].timeIndex1;
		if(db_writer->index < db_writer->hashes_size){
			uint64_t hash_with_time = (fp_hash << 16) + fp_time;
			db_writer->hashes[db_writer->index]= hash_with_time;
			db_writer->index++;
		}else{
			fprintf(stderr,"WARNING: Ignoring hashes consider increasing db_writer->hashes_size");
		}
	}
	fingerprints->fingerprintIndex = 0;
}

void olaf_fp_db_writer_delete( Olaf_FP_DB_Writer * db_writer , struct extracted_fingerprints * fingerprints ){
	//Not supported
	(void)(db_writer);
	(void)(fingerprints);
}


void olaf_fp_db_writer_destroy(Olaf_FP_DB_Writer * db_writer, bool store){

	(void)(store);

	if(db_writer->index > 0){
		qsort(db_writer->hashes, db_writer->index, sizeof(uint64_t), fp_hash_compare);

		printf("/**@file olaf_fp_ref_mem.h \n");
		printf(" * @brief The in-memory 'database' of fingerprints used to match queries against in the 'memory' configuration. \n");
		printf(" */\n");
		printf("#include <stdint.h>\n\n");

		printf("/**The array with fingerprints.*/\n");
		printf("const uint64_t olaf_db_mem_fps[] = {\n");
		for(size_t i = 0 ; i < db_writer->index;i++){
			printf("%llu,\n",db_writer->hashes[i]);
		}
		printf("};\n");
	}

	free(db_writer);
}

