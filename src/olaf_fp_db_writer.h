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

/**
 * @file olaf_fp_db_writer.h
 *
 * @brief Caches and finally writes fingerprints to the database.
 *
 */

#ifndef OLAF_FP_DB_WRITER_H
#define OLAF_FP_DB_WRITER_H
	#include <stdint.h>
	
	#include "olaf_db.h"
	#include "olaf_fp_extractor.h"
	
	/**
     * @struct Olaf_FP_DB_Writer
     * @brief An opaque struct with state information related to the stream processor.
     * 
     */
	typedef struct Olaf_FP_DB_Writer Olaf_FP_DB_Writer;

	/**
	 * @brief      Initialize a new db writer.
	 *
	 * @param      db                     The database.
	 * @param[in]  audio_file_identifier  The audio file identifier.
	 *
	 * @return     A newly initialized db writer struct. 
	 */
	Olaf_FP_DB_Writer * olaf_fp_db_writer_new(Olaf_DB* db,uint32_t audio_file_identifier);

	/**
	 * @brief      Cache and store fingerprints.
	 *
	 * @param      olaf_fp_db_writer  The olaf fp database writer.
	 * @param      fingerprints       The fingerprints.
	 */
	void olaf_fp_db_writer_store( Olaf_FP_DB_Writer * olaf_fp_db_writer, struct extracted_fingerprints * fingerprints);

	/**
	 * @brief      Cache and delete fingerprints.
	 *
	 * @param      olaf_fp_db_writer  The olaf fp database writer.
	 * @param      fingerprints       The fingerprints.
	 */
	void olaf_fp_db_writer_delete( Olaf_FP_DB_Writer * olaf_fp_db_writer, struct extracted_fingerprints * fingerprints);

	/**
	 * @brief      Free up memory and release resources.
	 *
	 * @param      olaf_fp_db_writer  The olaf fp database writer
	 * @param[in]  store              True if store needs to be called or false if delete needs to be called.
	 */
	void olaf_fp_db_writer_destroy(Olaf_FP_DB_Writer * olaf_fp_db_writer, bool store);

#endif //OLAF_FP_DB_WRITER_H
	
