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

	//the file size in samples
	//a float is expected to be 4 bytes
	size_t file_size_in_samples;

	//the index of the current sample being read
	//it should be smaller than file_size_in_samples
	size_t current_sample_index;

	//the audio data itself
	float* audio_data;
};


size_t min(size_t a, size_t b){
	if(a > b)
		return b;
	return a;
}

//reads the complete audio file from disk
Olaf_Reader * olaf_reader_new(Olaf_Config * config,const char * source){

	FILE *file;
	size_t fileSize;
	size_t result;

	file = fopen(source,"rb");  // r for read, b for binary

	if (file==NULL) {
		fprintf(stderr,"Audio file %s not found or unreadable.\n",source);
		exit (1);
	}

	//determine the duration in samples
	fseek (file , 0 , SEEK_END);
	fileSize = ftell (file);
	rewind (file);

	Olaf_Reader *reader = (Olaf_Reader*) malloc(sizeof(Olaf_Reader));
	reader->config = config;
	reader->file_size_in_samples = fileSize/sizeof(float);

	reader->current_sample_index = 0;

	// allocate memory to contain the whole file:
	reader->audio_data =  (float *)(malloc(fileSize));

	if (reader->audio_data == NULL) {fputs ("Not enough memory error",stderr); exit (2);}

	// copy the file into the audioData:
	result = fread (reader->audio_data,1,fileSize,file);
	if (result != fileSize) {fputs ("Reading error",stderr); exit (3);}
	fclose(file); // after reading the file to memory, close the file

	
	return reader;
}

//copy the next block 
size_t olaf_reader_read(Olaf_Reader *reader ,float * audio_block){
	
	size_t step_size = reader->config->audioStepSize;

	//make room for the new samples: shift the oldest to the beginning
	for(size_t i = 0 ; i < step_size;i++){
		audio_block[i]=audio_block[i+step_size];
	}

	size_t start_index = reader->current_sample_index;
	size_t stop_index = min(reader->current_sample_index + step_size,reader->file_size_in_samples);


	//start from the middle of the array
	size_t number_of_samples_read = 0;
	for(size_t i = start_index ; i < stop_index ; i++){
		audio_block[step_size+number_of_samples_read]=reader->audio_data[i];
		number_of_samples_read++;
	}

	//When reading the last buffer, make sure that the block is zero filled
	for(size_t i = number_of_samples_read ; i < step_size ;i++){
		audio_block[i] = 0;
	}

	reader->current_sample_index += number_of_samples_read;

	return number_of_samples_read;
}

//free the claimed resources
void olaf_reader_destroy(Olaf_Reader *  reader){
	free(reader->audio_data);
	free(reader);
}
