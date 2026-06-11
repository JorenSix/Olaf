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
 * @file olaf_db_mem_pack.h
 *
 * @brief Packs a fingerprint hash and time stamp into a single uint64_t for
 * the in-memory database: the 48 most significant bits hold the hash, the
 * 16 least significant bits the time stamp. Shared between olaf_db_mem.c
 * and the unit tests so the packing format has a single definition.
 *
 */

#ifndef OLAF_DB_MEM_PACK_H
#define OLAF_DB_MEM_PACK_H
	#include <stdint.h>

	static inline uint64_t olaf_db_mem_pack(uint64_t hash, uint32_t t){
		uint64_t packed = 0;
		packed = (hash<<16);
		packed += t;
		return packed;
	}

	static inline void olaf_db_mem_unpack(uint64_t packed, uint64_t * hash, uint32_t * t){
		*hash = (packed >> 16);
		*t = (uint32_t)((uint16_t) packed) ;
	}
#endif // OLAF_DB_MEM_PACK_H
