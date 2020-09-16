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
#ifndef OLAF_FP_DB_H
#define OLAF_FP_DB_H
	#include <stdbool.h>
	
	// The 'database' is either an array in memory or a LMDB instance.
	// It is essentialy a sorted list of uint64_t elements
	// Of the 64 bits:
	// - The 32 most significant bits are a hash
	// - The next 32 bits a time stamp 
	// 
	// This hash points to a 32 bits identifier of a song 
	//
	// About 13k fingerprints are used for a 4min song
	// 13k * 64bit =  100kB, with 20GB memory, +-200k songs can be stored
	// 
	typedef struct Olaf_FP_DB Olaf_FP_DB;

	//Create a new database, if the file name exists, read the contents
	Olaf_FP_DB * olaf_fp_db_new(const char * db_file_folder,bool readonly);

	//Store a list of elements in the memory store
	void olaf_fp_db_store(Olaf_FP_DB *, uint32_t * keys, uint64_t * values, size_t size);


	//Delete a list of elements in the memory store
	void olaf_fp_db_delete(Olaf_FP_DB *, uint32_t * keys, uint64_t * values, size_t size);

	//Find a list of elements in the memory store
	//only take into account the x most significant bits
	void olaf_fp_db_find(Olaf_FP_DB *,uint32_t key,int bits_to_ignore,uint64_t * results, size_t results_size, size_t * number_of_results);

	//Does the db contain this (single) key?
	bool olaf_fp_db_find_single(Olaf_FP_DB *,uint32_t key,int bits_to_ignore);

	//free memory resources and close resources
	void olaf_fp_db_destroy(Olaf_FP_DB * );

	//print database statistics
	void olaf_fp_db_stats(Olaf_FP_DB * olaf_fp_db);

	//hash  a string
	uint32_t olaf_fp_db_string_hash(const char *key, size_t len);

#endif // OLAF_FP_DB_H
