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


/**
 * @file olaf_fp_db_writer_cache.h
 *
 * @brief Reads fingerprints from a csv file and stores them in a database.
 *
 */

#ifndef OLAF_FP_DB_WRITER_CACHE_H
#define OLAF_FP_DB_WRITER_CACHE_H
	#include <stdint.h>
	#include <stdlib.h>
	#include <string.h>

	#include "olaf_db.h"
	#include "olaf_config.h"

	#define MAX_LINE_LEN 2048
	#define MAX_TOKEN_LEN 512
	#define FP_ARRAY_SIZE 10000
	
	/**
     * @struct Olaf_FP_DB_Writer_Cache
     * @brief An opaque struct with state information related to the cache writer.
     * 
     */
	typedef struct Olaf_FP_DB_Writer_Cache Olaf_FP_DB_Writer_Cache;

	/**
	 * @brief      Initializes a new cache db writer.
	 *
	 * @param      db            The database.
	 * @param      config        The configuration.
	 * @param[in]  csv_filename  The csv filename to parse and store.
	 *
	 * @return     Newly initialized state information.
	 */
	Olaf_FP_DB_Writer_Cache * olaf_fp_db_writer_cache_new(Olaf_DB* db,Olaf_Config * config,const char *csv_filename);

	/**
	 * @brief      Read the csv file and store the fingerpints within the file. Or an error if the CSV is malformed.
	 *
	 * @param      olaf_fp_db_writer_cache  The olaf fp database writer cache
	 */
	void olaf_fp_db_writer_cache_store( Olaf_FP_DB_Writer_Cache * olaf_fp_db_writer_cache);

	/**
	 * @brief      Free resources and close the CSV file.
	 *
	 * @param      olaf_fp_db_writer_cache  The olaf fp database writer cache
	 */
	void olaf_fp_db_writer_cache_destroy(Olaf_FP_DB_Writer_Cache * olaf_fp_db_writer_cache);

#endif //OLAF_FP_DB_WRITER_H
	

