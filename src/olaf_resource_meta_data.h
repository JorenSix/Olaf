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
 * @file olaf_db.h
 *
 * @brief Olaf fingerprint database.
 *
 * The interface to a data store with fingerprints. 
 * There are two implementations included in Olaf. 
 * A persistent key value store backed by a B-tree (LMDB) or an 
 * in memory store. 
 * 
 * The data store is a list of fingerprint hashes (uint64_t) 
 * pointing to a value (also uint64_t) The value consists of: * 
 * - The 32 least significant bits (uint32_t) are an audio identifier
 * - The next 32 bits (uint32_t) a time stamp
 * 
 * Hash collisions are possible so duplicates should be allowed.
 *
 */

#ifndef OLAF_RESOURCE_META_DATA_H
#define OLAF_RESOURCE_META_DATA_H
	#include <stdbool.h>
	#include <stdint.h>

    /**
	 * @struct Olaf_Resource_Meta_data
	 * @brief A struct containing meta data on indexed audio files
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

#endif // OLAF_RESOURCE_META_DATA_H