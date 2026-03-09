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
#include <stdlib.h>
#include <stdio.h>
#include <inttypes.h>
#include <string.h>

#include "olaf_fp_file_writer.h"
#include "olaf_fp_extractor.h"
#include "olaf_db.h"

struct Olaf_FP_File_Writer{
	FILE * output_file; /**< The output file handle for writing fingerprints */
};

Olaf_FP_File_Writer * olaf_fp_file_writer_new( FILE * output_file){
	Olaf_FP_File_Writer *file_writer = (Olaf_FP_File_Writer *) malloc(sizeof(Olaf_FP_File_Writer));
	file_writer->output_file = output_file;
	return file_writer;
}

void olaf_fp_file_writer_write_header(Olaf_FP_File_Writer * file_writer){
	fprintf(file_writer->output_file, "fp_hash, ");
	fprintf(file_writer->output_file, "t1, f1, m1, ");
	fprintf(file_writer->output_file, "t2, f2, m2, ");
	fprintf(file_writer->output_file, "t3, f3, m3\n");
}

void olaf_fp_file_writer_write( Olaf_FP_File_Writer * file_writer , struct extracted_fingerprints * fingerprints ){
	for(size_t i = 0 ; i < fingerprints->fingerprintIndex; i++){
		struct fingerprint f = fingerprints->fingerprints[i];
		fprintf(file_writer->output_file, "%"PRIu64 ", ", olaf_fp_extractor_hash(f));
		fprintf(file_writer->output_file, "%d, %d, %.6f, ", f.timeIndex1,f.frequencyBin1,f.magnitude1);
		fprintf(file_writer->output_file, "%d, %d, %.6f, ", f.timeIndex2,f.frequencyBin2,f.magnitude2);
		fprintf(file_writer->output_file, "%d, %d, %.6f\n", f.timeIndex3,f.frequencyBin3,f.magnitude3);
	}
}

void olaf_fp_file_writer_destroy(Olaf_FP_File_Writer * file_writer, Olaf_Resource_Meta_data * meta_data, FILE * fp_meta_file){


	if(file_writer->output_file != NULL && file_writer->output_file !=stdout) {
		fclose(file_writer->output_file);
	}

	fprintf(fp_meta_file, "path=%s\n", meta_data->path);
	fprintf(fp_meta_file, "duration=%.3f\n", meta_data->duration);
	fprintf(fp_meta_file, "fingerprints=%ld\n", meta_data->fingerprints);

	if(fp_meta_file != NULL && file_writer->output_file !=stdout) {
		fclose(fp_meta_file);
	}
	
	free(file_writer);
}
