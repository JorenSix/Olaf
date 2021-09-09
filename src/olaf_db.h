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
#ifndef OLAF_DB_H
#define OLAF_DB_H
	#include <stdbool.h>
	#include <stdint.h>
	
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
	typedef struct Olaf_DB Olaf_DB;

	//Create a new database, if the file name exists, read the contents
	Olaf_DB * olaf_db_new(const char * db_file_folder,bool readonly);

	//free memory resources and close resources
	void olaf_db_destroy(Olaf_DB * );


	//####META DATA methods

	typedef struct Olaf_Resource_Meta_data Olaf_Resource_Meta_data;

	struct Olaf_Resource_Meta_data{
		//duration of the audio file in seconds
		float duration;
		//The number of fingerprints extracted from the audio file
		long fingerprints;

		//The path of the audio file
		char path[512];
	};

	//store the meta data 
	void olaf_db_store_meta_data(Olaf_DB *, uint32_t * key, Olaf_Resource_Meta_data * value);

	//search for meta data
	void olaf_db_find_meta_data(Olaf_DB * , uint32_t * key, Olaf_Resource_Meta_data * value);

	//Delete meta data 
	void olaf_db_delete_meta_data(Olaf_DB * , uint32_t * key);

	//Check if there is meta data for a key
	bool olaf_db_has_meta_data(Olaf_DB * , uint32_t * key);

	//Print meta database statistics
	void olaf_db_stats_meta_data(Olaf_DB *,bool verbose);

	
	//####Finger print methods

	//Store a list of elements in the memory store
	void olaf_db_store(Olaf_DB *, uint64_t * keys, uint64_t * values, size_t size);

	//Delete a list of elements in the memory store
	void olaf_db_delete(Olaf_DB *, uint64_t * keys, uint64_t * values, size_t size);

	//Find a list of elements in the memory store
	//only take into account the x most significant bits
	size_t olaf_db_find(Olaf_DB *,uint64_t start_key,uint64_t stop_key,uint64_t * results, size_t results_size);

	bool olaf_db_find_single(Olaf_DB * olaf_db,uint64_t start_key,uint64_t stop_key);

	//print database statistics
	void olaf_db_stats(Olaf_DB *,bool verbose);

	//hash  a string
	uint32_t olaf_db_string_hash(const char *key, size_t len);

#endif // OLAF_DB_H
