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

#include "olaf_fp_file_writer.h"
#include "olaf_fp_extractor.h"

struct Olaf_FP_File_Entry{
	uint64_t hash;
	uint64_t value;
};

struct Olaf_FP_File_Writer{
	struct Olaf_FP_File_Entry * entries;
	size_t entry_index;
	size_t entries_size;
	uint32_t audio_file_identifier;
	Olaf_Config * config;
};

Olaf_FP_File_Writer * olaf_fp_file_writer_new(Olaf_Config * config, uint32_t audio_file_identifier){

	Olaf_FP_File_Writer *file_writer = (Olaf_FP_File_Writer *) malloc(sizeof(Olaf_FP_File_Writer));

	file_writer->entries_size = 1<<15;//over 9000
	file_writer->entries = (struct Olaf_FP_File_Entry *) calloc(file_writer->entries_size,sizeof(struct Olaf_FP_File_Entry));
	file_writer->entry_index=0;
	file_writer->audio_file_identifier = audio_file_identifier;
	file_writer->config = config;
	
	return file_writer;
}

void olaf_fp_file_writer_grow_table(Olaf_FP_File_Writer * file_writer){
	size_t current_entries_size = file_writer->entries_size;
	struct Olaf_FP_File_Entry * current_entries = file_writer->entries;

	file_writer->entries_size = current_entries_size * 2;
	file_writer->entries = (struct Olaf_FP_File_Entry *) calloc(file_writer->entries_size,sizeof(struct Olaf_FP_File_Entry));

	for(size_t i = 0 ; i < current_entries_size; i++){
		file_writer->entries[i] = current_entries[i]; 
	}

	//printf("Grown entries size to %zu \n",file_writer->entries_size);

	free(current_entries);
}

void olaf_fp_file_writer_store( Olaf_FP_File_Writer * file_writer , struct extracted_fingerprints * fingerprints ){

	for(size_t i = 0 ; i < fingerprints->fingerprintIndex; i++){

		uint32_t hash = olaf_fp_extractor_hash(fingerprints->fingerprints[i]);
		uint64_t fingerprint_t1 = fingerprints->fingerprints[i].timeIndex1;
		uint64_t fingerprint_id = file_writer->audio_file_identifier;
		uint64_t value = (fingerprint_t1<<32) + fingerprint_id;

		file_writer->entries[file_writer->entry_index].hash = hash;
		file_writer->entries[file_writer->entry_index].value = value;

		file_writer->entry_index++;

		if(file_writer->entry_index == file_writer->entries_size){
			olaf_fp_file_writer_grow_table(file_writer);
		}
	}
	fingerprints->fingerprintIndex = 0;
}

int olaf_fp_file_writer_compare_entries(const void * a, const void * b) {
	struct Olaf_FP_File_Entry a_file_entry = *(struct Olaf_FP_File_Entry*)a;
	struct Olaf_FP_File_Entry b_file_entry = *(struct Olaf_FP_File_Entry*)b;

	//sort by hash
	if(a_file_entry.hash != b_file_entry.hash){
		return a_file_entry.hash > b_file_entry.hash ? 1 : -1;
	}

	//if hash is equal, sort by value
	if( a_file_entry.value == b_file_entry.value){
		return 0;
	}

	return a_file_entry.value > b_file_entry.value ? 1 : -1;
}

void olaf_fp_file_writer_destroy(Olaf_FP_File_Writer * file_writer){

	if(file_writer->entry_index > 0){

		char tdb_file_name[50];
		snprintf(tdb_file_name, 50, "%u.tdb", file_writer->audio_file_identifier);

		char * full_tdb_name = (char *) malloc(strlen(file_writer->config->dbFolder) +  strlen(tdb_file_name));
		strcpy(full_tdb_name,file_writer->config->dbFolder);
		strcat(full_tdb_name,tdb_file_name);

		FILE *temp_db_file;
		if ((temp_db_file = fopen(full_tdb_name,"w")) == NULL){
			printf("Error! opening file");
		}

		//sort results by match count, lowest match count first
		qsort(file_writer->entries, file_writer->entries_size, sizeof(struct Olaf_FP_File_Entry), olaf_fp_file_writer_compare_entries);


		for(size_t i = 0 ; i < file_writer->entry_index;i++){
			fprintf(temp_db_file,"%llu,%llu\n",file_writer->entries[i].hash,file_writer->entries[i].value);
		}

		fclose(temp_db_file);
		free(full_tdb_name);
	}

	free(file_writer->entries);
	free(file_writer);
}
