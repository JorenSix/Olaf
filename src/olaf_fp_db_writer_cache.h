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

	typedef struct Olaf_FP_DB_Writer_Cache Olaf_FP_DB_Writer_Cache;

	Olaf_FP_DB_Writer_Cache * olaf_fp_db_writer_cache_new(Olaf_DB* db,Olaf_Config *,const char *csv_filename);

	void olaf_fp_db_writer_cache_store( Olaf_FP_DB_Writer_Cache * );

	void olaf_fp_db_writer_cache_destroy(Olaf_FP_DB_Writer_Cache *);

#endif //OLAF_FP_DB_WRITER_H
	

/*


int main(int argc, char *argv[]) {
    if (argc < 2) {
        printf("Usage: %s <csv file>\n", argv[0]);
        return -1;
    }

    uint64_t values[MAX_TOKEN_LEN * MAX_LINE_LEN];
    int count = read_csv_file(argv[1], values);
    if (count < 0) {
        return -1;
    }

    printf("Parsed %d values:\n", count);
    for (int i = 0; i < count; i++) {
        printf("%lu\n", values[i]);
    }

    return 0;
}
*/
