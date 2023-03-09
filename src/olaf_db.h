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

/**
 * @file olaf_db.h
 *
 * @brief Olaf fingerprint database.
 *
 * The 'database' is either an array in memory or a LMDB key value store.
 * It is essentialy a sorted list of uint64_t elements
 * Of the 64 bits:
 * - The 32 most significant bits are a hash
 * - The next 32 bits a time stamp 
 * 
 * This hash points to a 32 bits identifier of a song 
 *
 *
 */

#ifndef OLAF_DB_H
#define OLAF_DB_H
	#include <stdbool.h>
	#include <stdint.h>
	

	typedef struct Olaf_DB Olaf_DB;

	/** 
	 * Creates a new database, if the file name exists, read the contents
	 * @param db_file_folder  The folder used to store database files
	 * @param readonly The mode to open the database, if no write operations are expected this should be true.
	 */
	Olaf_DB * olaf_db_new(const char * db_file_folder,bool readonly);

	/**
	 * Free database related memory resources and close files or other resources.
	 * @param db the database to close.
	 */
	void olaf_db_destroy(Olaf_DB * db);


	/**
	 * @struct Olaf_Resource_Meta_data
	 * @brief A struct containging meta data on indexed audio files
	 * 
	 */
	typedef struct Olaf_Resource_Meta_data Olaf_Resource_Meta_data;

	struct Olaf_Resource_Meta_data{
		/** Duration of the audio file in seconds. */
		float duration;
		/** The number of fingerprints extracted from the audio file. */
		long fingerprints;
		/** The path of the audio file, limited to 512 characters! */
		char path[512];
	};

	/**
	 * Store meta-data.
	 * @param db The database to store info in.
	 * @param key The audio identifier.
	 * @param value The meta-data with information on the audio.
	 */
	void olaf_db_store_meta_data(Olaf_DB * db, uint32_t * key, Olaf_Resource_Meta_data * value);

	/**
	 * Search meta-data.
	 * @param db The database.
	 * @param key The audio identifier.
	 * @param value Where to store meta-data information on the audio.
	 */
	void olaf_db_find_meta_data(Olaf_DB * db , uint32_t * key, Olaf_Resource_Meta_data * value);

	/**
	 * Delete meta-data.
	 * @param db The database.
	 * @param key The audio identifier to delete meta-data for.-
	 */
	void olaf_db_delete_meta_data(Olaf_DB * db , uint32_t * key);

	/**
	 * Check if there is meta data for a key.
	 * @param db The database.
	 * @param key The audio identifier.
	 * @return  True if meta-data is available.
	 */
	bool olaf_db_has_meta_data(Olaf_DB * db , uint32_t * key);


	/**
	 * Print meta database statistics.
	 * @param db The database.
	 * @param verbose Print more information than usual.
	 */
	void olaf_db_stats_meta_data(Olaf_DB * db,bool verbose);

	
	//####Finger print methods

	/**
	 * Store a list of elements in the data store.
	 * @param db The database.
	 * @param keys A list of keys: the 64bit fingerprint hash.
	 * @param values A list of values: Typically the highest 32bits contain a timestamp, the lowest 32bits an audio identifier.
	 * @param size The size of both the keys and values arrays.
	 */
	void olaf_db_store(Olaf_DB * db, uint64_t * keys, uint64_t * values, size_t size);

	/**
	 * Delete a list of elements in the data store.
	 * @param db The database.
	 * @param keys A list of keys: the 64bit fingerprint hash.
	 * @param values A list of values: Typically the highest 32bits contain a timestamp, the lowest 32bits an audio identifier.
	 * @param size The size of both the keys and values arrays.
	 */
	void olaf_db_delete(Olaf_DB * db, uint64_t * keys, uint64_t * values, size_t size);

	//Find a list of elements in the memory store
	//only take into account the x most significant bits

	size_t olaf_db_find(Olaf_DB * db,uint64_t start_key,uint64_t stop_key,uint64_t * results, size_t results_size);


	bool olaf_db_find_single(Olaf_DB * db,uint64_t start_key,uint64_t stop_key);

	/**
	 * Print database statistics.
	 * @param db The database.
	 * @param verbose Print more information than usual.
	 */
	void olaf_db_stats(Olaf_DB * db,bool verbose);

	/**
	 * Hash a string into a 32 bit integer e.g. using a Jenkins hash. This can be practial to convert an audio 
	 * file name into an identifier.
	 * @param key The list of characters.
	 * @param len The length of the string.
	 */
	uint32_t olaf_db_string_hash(const char *key, size_t len);

#endif // OLAF_DB_H
