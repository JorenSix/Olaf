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
 * @file olaf_db_id.c
 *
 * @brief Audio identifier hashing, shared by all database implementations
 * (olaf_db.c and olaf_db_mem.c). Declared in olaf_db.h.
 *
 */
#include <stdint.h>
#include <stddef.h>

#include "olaf_db.h"

//string to unsigned 32 bit hash
uint32_t olaf_db_string_hash(const char *key, size_t len){

	//from wikipedia: jenkins_one_at_a_time_hash
	//https://en.wikipedia.org/wiki/Jenkins_hash_function
	uint32_t hash, i;

	for(hash = i = 0; i < len; ++i){
		hash += key[i];
		hash += (hash << 10);
		hash ^= (hash >> 6);
	}

	hash += (hash << 3);
	hash ^= (hash >> 11);
	hash += (hash << 15);

	return hash;
}

// Reject empty input and multi-digit values with a leading zero so that
// "0123" and "123" don't collapse to the same key. Anything that doesn't
// look like a clean decimal number in u32 range falls back to the hash.
uint32_t olaf_db_identifier_id(const char *identifier, size_t len){
	if(identifier == NULL || len == 0) return olaf_db_string_hash(identifier, len);
	if(len > 1 && identifier[0] == '0') return olaf_db_string_hash(identifier, len);
	if(len > 10) return olaf_db_string_hash(identifier, len); // u32 max is 4294967295 (10 digits)

	uint64_t value = 0;
	for(size_t i = 0; i < len; i++){
		char c = identifier[i];
		if(c < '0' || c > '9') return olaf_db_string_hash(identifier, len);
		value = value * 10 + (uint64_t)(c - '0');
		if(value > 0xFFFFFFFFULL) return olaf_db_string_hash(identifier, len);
	}
	return (uint32_t)value;
}
