#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include <string.h>
#include <stdbool.h>
#include <time.h>
#include <libgen.h>

#include "pffft.h"

#include "olaf_window.h"
#include "olaf_config.h"
#include "olaf_audio_reader.h"
#include "olaf_ep_extractor.h"
#include "olaf_fp_extractor.h"
#include "olaf_fp_db.h"
#include "olaf_fp_matcher.h"
#include "olaf_fp_db_writer.h"


int main(int argc, const char* argv[]){


	if(argc < 2){
		fprintf(stderr,"No file name given. Use \n olaf_c [query audio.raw | store raw_audio.raw id | stats | name_to_id file_name]\n");
		exit(-10);
	}

	const char* command = argv[1];

	//Get the default configuration
	Olaf_Config *config = olaf_config_default();

	bool readonly_db = true;
	bool match = false;

	if(strcmp(command,"store") == 0){
		readonly_db = false;
		match = false;

		if(argc != 4){
			fprintf(stderr,"No file name given. Use \n olaf [query audio.raw | store raw_audio.raw id | stats | name_to_id]\n");
			exit(-10);
		}

	}else if(strcmp(command,"query") == 0){
		match = true;
	}else if(strcmp(command,"name_to_id") == 0){
		//print the hash an exit
		printf("%u\n",olaf_fp_db_string_hash(argv[2],strlen(argv[2])));
		exit(0);
		return 0;
	} else if(strcmp(command,"stats") == 0){
		//print database statistics and exit
		Olaf_FP_DB* db = olaf_fp_db_new(config->dbFolder,readonly_db);
		olaf_fp_db_stats(db);
		olaf_fp_db_destroy(db);
		exit(0);
		return 0;
	}
	
	Olaf_FP_DB* db = olaf_fp_db_new(config->dbFolder,readonly_db);
	Olaf_EP_Extractor *ep_extractor = olaf_ep_extractor_new(config);
	Olaf_FP_Extractor *fp_extractor = olaf_fp_extractor_new(config);
	Olaf_FP_Matcher *fp_matcher = NULL;
	Olaf_FP_DB_Writer *fp_db_writer = NULL;

	//Initialize one or other, otherwise database is read from disk twice!
	//so twice the memory usage
	if(match){
		fp_matcher = olaf_fp_matcher_new(config,db);
	} else {
		//to store a 
		uint32_t audio_file_identifier = (uint32_t) strtoul(argv[3],NULL,0);
		fp_db_writer = olaf_fp_db_writer_new(db,audio_file_identifier);
	}
	
	//the samples should be a 32bit float
	int bytesPerAudioBlock = config->audioBlockSize * config->bytesPerAudioSample;

	//initialize the pfft object
	// We will use a size of audioblocksize 
	// We are only interested in real part
	PFFFT_Setup *fftSetup = pffft_new_setup(config->audioBlockSize,PFFFT_REAL);
	float *fft_in = (float*) pffft_aligned_malloc(bytesPerAudioBlock);//fft input
	float *fft_out= (float*) pffft_aligned_malloc(bytesPerAudioBlock);//fft output

	//the current audio block index
	int audioBlockIndex = 0;

	struct olaf_audio audio;

	struct extracted_event_points * eventPoints = NULL;
	struct extracted_fingerprints * fingerprints;

	//read the complete audio file in memory
	olaf_audio_reader_read(argv[2],&audio);

	//a precomputed window of 512 samples is used.
	//the audio block size should be the same
	assert(config->audioBlockSize == 512);

	//The raw format and size of float should be 32 bits
	assert(config->bytesPerAudioSample == sizeof(float));

	//fprintf(stderr,"Input audio is %ld s long (%ld samples) \n", audio.fileSizeInSamples/config->audioSampleRate,audio.fileSizeInSamples );

	clock_t start, end;
    double cpu_time_used;
    start = clock();

	for(size_t i = 0; i <  audio.fileSizeInSamples - config->audioBlockSize; i += config->audioStepSize){

		// windowing + copy to fft input
		for(int j = 0 ; j <  config->audioBlockSize ; j++){
			fft_in[j] = audio.audioData[i+j] * gaussian_window[j];
		}

		//do the transform
		pffft_transform_ordered(fftSetup, fft_in, fft_out, 0, PFFFT_FORWARD);

		//extract event points
		eventPoints  =  olaf_ep_extractor_extract(ep_extractor,fft_out,audioBlockIndex);

		//fprintf(stderr,"Current event point index %d \n",  eventPoints->eventPointIndex);

		//if there are enough event points
		if(eventPoints->eventPointIndex > config->eventPointThreshold){

			//combine the event points into fingerprints
			fingerprints = olaf_fp_extractor_extract(fp_extractor,eventPoints,audioBlockIndex);

			if(match){
				//use the fingerprints to match with the reference database
				//report matches if found
				olaf_fp_matcher_match(fp_matcher,fingerprints);
			}else{
				//use the fp's to store in the db
				olaf_fp_db_writer_write(fp_db_writer,fingerprints);
			}
		}
		//increase the audio buffer counter
		audioBlockIndex++;
	}


	//handle the last event points
	fingerprints = olaf_fp_extractor_extract(fp_extractor,eventPoints,audioBlockIndex);
	

	//handle the last fingerprints
	if(match){
		olaf_fp_matcher_match(fp_matcher,fingerprints);
	}else{
		//use the fp's to write header file
		olaf_fp_db_writer_write(fp_db_writer,fingerprints);
	}


	//for timing statistics
	end = clock();
	//fprintf(stderr,"end %lu \n",end);
    cpu_time_used = ((double) (end - start)) / CLOCKS_PER_SEC;
    double audioDuration = (double) audio.fileSizeInSamples / (double) config->audioSampleRate;
    double ratio = audioDuration / cpu_time_used; 

	//cleanup fft structures
	pffft_aligned_free(fft_in);
	pffft_aligned_free(fft_out);
	pffft_destroy_setup(fftSetup);

	//free the audio data memory block
	free(audio.audioData);

	//free olaf memory and close resources
	if(match){
		olaf_fp_matcher_destroy(fp_matcher);
	} else {
		olaf_fp_db_writer_destroy(fp_db_writer);
	}

	olaf_fp_extractor_destroy(fp_extractor);
	olaf_ep_extractor_destroy(ep_extractor);
	olaf_fp_db_destroy(db);
	olaf_config_destroy(config);

	fprintf(stderr,"Proccessed %.1fs in %.3fs (%.0f times realtime)\n", audioDuration,cpu_time_used,ratio);
	
	return 0;
}
