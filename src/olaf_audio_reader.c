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
#include "olaf_audio_reader.h"
#include <stdio.h>
#include <stdlib.h>

void olaf_audio_reader_read(const char* filename,struct olaf_audio* audio){
	FILE *file;
	size_t fileSize;
	size_t result;

	file = fopen(filename,"rb");  // r for read, b for binary

	if (file==NULL) {
		fprintf(stderr,"Audio file %s not found or unreadable.\n",filename);
		exit (1);
	}

	//determine the duration in samples
	fseek (file , 0 , SEEK_END);
	fileSize = ftell (file);
	rewind (file);
	audio->fileSizeInSamples = fileSize/sizeof(float);

	// allocate memory to contain the whole file:
	audio->audioData =  (float *)(malloc(fileSize));

	if (audio->audioData == NULL) {fputs ("Not enough memory error",stderr); exit (2);}

	// copy the file into the audioData:
	result = fread (audio->audioData,1,fileSize,file);
	if (result != fileSize) {fputs ("Reading error",stderr); exit (3);}
	fclose(file); // after reading the file to memory, close the file
}
