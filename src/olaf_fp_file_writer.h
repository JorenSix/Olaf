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
#ifndef OLAF_FP_FILE_WRITER_H
#define OLAF_FP_FILE_WRITER_H
	#include <stdint.h>

	#include "olaf_fp_extractor.h"

	typedef struct Olaf_FP_File_Writer Olaf_FP_File_Writer;

	Olaf_FP_File_Writer * olaf_fp_file_writer_new(Olaf_Config * , uint32_t audio_file_identifier);

	void olaf_fp_file_writer_store( Olaf_FP_File_Writer * , struct extracted_fingerprints * );

	void olaf_fp_file_writer_destroy(Olaf_FP_File_Writer *);

#endif //OLAF_FP_FILE_WRITER_H
	
