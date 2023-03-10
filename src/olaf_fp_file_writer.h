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
 * @file olaf_fp_file_writer.h
 *
 * @brief Olaf fingerprint extractor: combines event points into fingerprints.
 *
 * The fingerprint extractor is responsible for combining event points into
 * fingerprints and also defines the fingerprint struct.
 */

#ifndef OLAF_FP_FILE_WRITER_H
#define OLAF_FP_FILE_WRITER_H
	#include <stdint.h>

	#include "olaf_fp_extractor.h"
	
	/**
	 * @struct Olaf_FP_File_Writer
	 * 
	 * @brief A struct to keep the internal state of the file writer hidden. It should 
	 * not be used in other places.
	 */
	typedef struct Olaf_FP_File_Writer Olaf_FP_File_Writer;

	/**
	 * @brief      Create a new file writer
	 *
	 * @param      olaf_config            The olaf configuration with the location to store the cached file.
	 * @param[in]  audio_file_identifier  The audio file identifier. The audio file identifier is used in the file name.
	 *
	 * @return     State information related to file writer.
	 */
	Olaf_FP_File_Writer * olaf_fp_file_writer_new(Olaf_Config * olaf_config, uint32_t audio_file_identifier);

	/**
	 * @brief      Store fingerprints in memory to write to a file later on.
	 *
	 * @param      olaf_fp_file_writer  The olaf fp file writer state information.
	 * @param      fingerprints         The fingerprint list to store.
	 */
	void olaf_fp_file_writer_store( Olaf_FP_File_Writer * olaf_fp_file_writer , struct extracted_fingerprints * fingerprints);

	/**
	 * @brief      Free resources related to the file writer. Also 
	 * write the fingerprints to a ".tdb" file in the configured cache directory. 
	 *
	 * @param      olaf_fp_file_writer  The olaf fp file writer state info.
	 */
	void olaf_fp_file_writer_destroy(Olaf_FP_File_Writer * olaf_fp_file_writer);

#endif //OLAF_FP_FILE_WRITER_H
	
