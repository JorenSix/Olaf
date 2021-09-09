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

#include <stdlib.h>
#include <stdio.h>

#include "olaf_config.h"
#include "olaf_reader.h"

struct Olaf_Reader{
	//the olaf configuration
	Olaf_Config* config;

	//The file currently being read
	FILE* audio_file;

	//have we reached the end of the file?
	bool end_of_file_reached;
};

Olaf_Reader * olaf_reader_new(Olaf_Config * config,const char * source){


	FILE* file = fopen(source,"rb");  // r for read, b for binary

	if (file==NULL) {
		fprintf(stderr,"Audio file %s not found or unreadable.\n",source);
		exit(1);
	}

	Olaf_Reader *reader = malloc(sizeof(Olaf_Reader));
	reader->config = config;
	reader->audio_file = file;
	reader->end_of_file_reached = true;

	return reader;
}

size_t olaf_reader_read(Olaf_Reader *reader ,float * audio_block){
	
	size_t number_of_samples_read;

	size_t step_size = reader->config->audioStepSize;

	//make room for the new samples: shift the oldest to the beginning
	for(size_t i = 0 ; i < step_size;i++){
		audio_block[i]=audio_block[i+step_size];
	}

	//start from the middle of the array
	float* startAddress = &audio_block[step_size];

	// copy the file into the audioData:
	number_of_samples_read = fread(startAddress,reader->config->bytesPerAudioSample,step_size,reader->audio_file);

	//When reading the last buffer, make sure that the block is zero filled
	for(size_t i = number_of_samples_read ; i < step_size ;i++){
		audio_block[i] = 0;
	}

	
	if(feof(reader->audio_file)) {
      reader->end_of_file_reached = true;
    }

	return number_of_samples_read;
}

void olaf_reader_destroy(Olaf_Reader *  reader){

	if(!reader->end_of_file_reached){
		printf(stderr, "Warning: not reached end of file\n");
	}	

	// after reading the file to memory, close the file
	fclose(reader->audio_file); 
	free(reader);
}
