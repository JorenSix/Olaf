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
#include "olaf_reader.h"
#include "olaf_ep_extractor.h"
#include "olaf_fp_extractor.h"
#include "olaf_fp_db.h"
#include "olaf_fp_matcher.h"
#include "olaf_fp_db_writer.h"
#include "olaf_fp_file_writer.h"

void print_help(const char* message){
	fprintf(stderr,"%s",message);
	fprintf(stderr,"\tolaf_c [query audio.raw | store [raw_audio.raw id] ... | bulk_store [raw_audio.raw id] ... | bulk_load | stats | name_to_id file_name | del raw_audio.raw id ]\n");
	exit(-10);
}

enum olaf_command {query = 0, store = 1, del = 4,bulk_store = 5, print = 6}; 


//performance shortcut to bulk load ordered 
//fingerprints from bulk_stored values
void olaf_bulk_load(){
	Olaf_FP_DB* db = NULL;

	Olaf_Config *config = olaf_config_default();
	db = olaf_fp_db_new(config->dbFolder,false);

	const char * tdb_file_name = "sorted.tdb";
	char * full_tdb_name = (char *) malloc(strlen(config->dbFolder) +  strlen(tdb_file_name));
	strcpy(full_tdb_name,config->dbFolder);
	strcat(full_tdb_name,tdb_file_name);

	printf("Opening file at: %s\n",tdb_file_name);

	FILE *ordered_fp_file=fopen(full_tdb_name, "r");
	size_t line_size=64;
	char line_buf[64];
	char *b = line_buf;
	size_t line_len=0;

	uint32_t keys[10000];
	uint64_t values[10000];
	size_t index = 0;

	size_t fp_counter = 0;

	while ((line_len=getline(&b, &line_size, ordered_fp_file)>0)) {
	  
	  char* char_key = strtok(line_buf, ",");
	  char* char_value = strtok(NULL, ",");

	  uint32_t key = strtoul(char_key, NULL, 0);
	  uint64_t value = strtoul(char_value, NULL, 0);

	  keys[index] = key;
	  values[index] = value;

	  //printf("%s %u -- %llu %s",char_key, key , value, char_value);

	  if(index == 10000){
	  	olaf_fp_db_store_bulk(db, keys, values, 10000);
	  	index = 0;
	  	printf("fp %zu \n",fp_counter);
	  }
	  index++;

	  fp_counter++;
	}

	fclose(ordered_fp_file);

	olaf_fp_db_store_bulk(db, keys, values, index);

	olaf_fp_db_destroy(db);
}

void olaf_print_fp(struct fingerprint fp){
	int timeIndex1=fp.timeIndex1;
	int frequencyBin1=fp.frequencyBin1;
	
	int timeIndex2=fp.timeIndex2;
	int frequencyBin2=fp.frequencyBin2;
	

	uint32_t hash = olaf_fp_extractor_hash(fp);

	printf("%u,%d,%d,%d,%d\n",hash,timeIndex1,frequencyBin1,timeIndex2,frequencyBin2);
}

int main(int argc, const char* argv[]){


	if(argc < 2){
		print_help("No filename given\n");
	}

	const char* command = argv[1];
	enum olaf_command cmd = query; 

	//Get the default configuration
	Olaf_Config *config = olaf_config_default();
	
	if(strcmp(command,"store") == 0){
		cmd = store;
	} else if(strcmp(command,"bulk_store") == 0){
		cmd = bulk_store;
	} else if(strcmp(command,"bulk_load") == 0){
		//print database statistics and exit
		olaf_bulk_load();
		exit(0);
		return 0;
	} else if(strcmp(command,"query") == 0){
		cmd = query;
	} else if(strcmp(command,"del") == 0){
		cmd = del;
	} else if(strcmp(command,"print") == 0){
		cmd = print;
	} else if(strcmp(command,"name_to_id") == 0){
		//print the hash an exit
		printf("%u\n",olaf_fp_db_string_hash(argv[2],strlen(argv[2])));
		exit(0);
		return 0;
	} else if(strcmp(command,"stats") == 0){
		//print database statistics and exit
		Olaf_FP_DB* db = olaf_fp_db_new(config->dbFolder,true);
		olaf_fp_db_stats(db);
		olaf_fp_db_destroy(db);
		exit(0);
		return 0;
	}else {
		
	}


	bool readonly_db = (cmd == query || cmd == bulk_store || cmd == print);
	
	Olaf_FP_DB* db = NULL;

	if(cmd == query || cmd == store ) { 
		db = olaf_fp_db_new(config->dbFolder,readonly_db);
	}

	//the samples should be a 32bit float
	int bytesPerAudioBlock = config->audioBlockSize * config->bytesPerAudioSample;
	//initialize the pfft object
	// We will use a size of audioblocksize 
	// We are only interested in real part
	PFFFT_Setup *fftSetup = pffft_new_setup(config->audioBlockSize,PFFFT_REAL);
	float *fft_in = (float*) pffft_aligned_malloc(bytesPerAudioBlock);//fft input
	float *fft_out= (float*) pffft_aligned_malloc(bytesPerAudioBlock);//fft output


	int arg_increment = (cmd == query || cmd == print) ? 1 : 2;

	//for each audio file

	for(int arg_index = 2 ; arg_index < argc ; arg_index+=arg_increment){
		//the current audio block index
		int audioBlockIndex = 0;

		size_t tot_samples_read = 0;
		size_t tot_fp_extracted = 0;

		Olaf_EP_Extractor *ep_extractor = olaf_ep_extractor_new(config);
		Olaf_FP_Extractor *fp_extractor = olaf_fp_extractor_new(config);
		Olaf_FP_Matcher *fp_matcher = NULL;
		Olaf_FP_DB_Writer *fp_db_writer = NULL;
		Olaf_FP_File_Writer *fp_file_writer = NULL;

		//Initialize one or other, otherwise database is read from disk twice!
		//so twice the memory usage
		if(cmd == query || cmd == print){
			fp_matcher = olaf_fp_matcher_new(config,db);
		} else {
			//to store or delete fingerprints
			uint32_t audio_file_identifier = (uint32_t) strtoul(argv[arg_index+1],NULL,0);
			if(cmd == bulk_store)
				fp_file_writer = olaf_fp_file_writer_new(config,audio_file_identifier);
			else{
				fp_db_writer = olaf_fp_db_writer_new(db,audio_file_identifier);
			}			
		}

		//audio reader
		Olaf_Reader *reader = olaf_reader_new(config,argv[arg_index]);

		struct extracted_event_points * eventPoints = NULL;
		struct extracted_fingerprints * fingerprints;

		//a precomputed window of 512 samples is used.
		//the audio block size should be the same
		assert(config->audioBlockSize == 512);

		float audio_data[512];

		//The raw format and size of float should be 32 bits
		assert(config->bytesPerAudioSample == sizeof(float));

		//fprintf(stderr,"Input audio is %ld s long (%ld samples) \n", audio.fileSizeInSamples/config->audioSampleRate,audio.fileSizeInSamples );

		size_t samples_read = olaf_reader_read(reader,audio_data);
		tot_samples_read += samples_read;

		size_t samples_expected = config->audioStepSize;

		clock_t start, end;
	    double cpu_time_used;
	    start = clock();

		while(samples_read==samples_expected){

			samples_read = olaf_reader_read(reader,audio_data);
			tot_samples_read += samples_read;

			// windowing + copy to fft input
			for(int j = 0 ; j <  config->audioBlockSize ; j++){
				fft_in[j] = audio_data[j] * gaussian_window[j];
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

				tot_fp_extracted = tot_fp_extracted + fingerprints->fingerprintIndex;

				if(cmd == query){
					//use the fingerprints to match with the reference database
					//report matches if found
					olaf_fp_matcher_match(fp_matcher,fingerprints);
				}else if(cmd == store){
					//use the fp's to store in the db
					olaf_fp_db_writer_store(fp_db_writer,fingerprints);
				} else if(cmd == del){
					olaf_fp_db_writer_delete(fp_db_writer,fingerprints);
				} else if(cmd == bulk_store){
					olaf_fp_file_writer_store(fp_file_writer,fingerprints);
				} else if(cmd == print){
					for(size_t i = 0 ; i < fingerprints->fingerprintIndex; i++){
						olaf_print_fp(fingerprints->fingerprints[i]);
					}
					fingerprints->fingerprintIndex = 0;
				}
			}
			//increase the audio buffer counter
			audioBlockIndex++;
		}

		//handle the last event points
		fingerprints = olaf_fp_extractor_extract(fp_extractor,eventPoints,audioBlockIndex);

		//handle the last fingerprints
		if(cmd == query){
			//use the fingerprints to match with the reference database
			//report matches if found
			olaf_fp_matcher_match(fp_matcher,fingerprints);
		} else if(cmd == store) {
			//use the fp's to store in the db
			olaf_fp_db_writer_store(fp_db_writer,fingerprints);
		} else if(cmd == del){
			olaf_fp_db_writer_delete(fp_db_writer,fingerprints);
		} else if(cmd == bulk_store){
			olaf_fp_file_writer_store(fp_file_writer,fingerprints);
		}else if(cmd == print){
			for(size_t i = 0 ; i < fingerprints->fingerprintIndex; i++){
				olaf_print_fp(fingerprints->fingerprints[i]);
			}
			fingerprints->fingerprintIndex = 0;
		}

	    olaf_reader_destroy(reader);

		//free olaf memory and close resources
		if(cmd == query){
			//print results
			olaf_fp_matcher_print_results(fp_matcher);
			olaf_fp_matcher_destroy(fp_matcher);
		} else if(cmd == store) {
			//use the fp's to store in the db
			olaf_fp_db_writer_destroy(fp_db_writer,true);
		} else if(cmd == del){
			olaf_fp_db_writer_destroy(fp_db_writer,false);
		} else if(cmd == bulk_store){
			olaf_fp_file_writer_destroy(fp_file_writer);
		}
		
		olaf_fp_extractor_destroy(fp_extractor);
		olaf_ep_extractor_destroy(ep_extractor);

		//for timing statistics
		end = clock();
	    cpu_time_used = ((double) (end - start)) / CLOCKS_PER_SEC;
	    double audioDuration = (double) tot_samples_read / (double) config->audioSampleRate;
	    double ratio = audioDuration / cpu_time_used;
	    fprintf(stderr,"Proccessed %lu fp's from %.1fs in %.3fs (%.0f times realtime) \n",tot_fp_extracted, audioDuration,cpu_time_used,ratio);
	}

	//cleanup fft structures
	pffft_aligned_free(fft_in);
	pffft_aligned_free(fft_out);
	pffft_destroy_setup(fftSetup);

	if(db!= NULL){
		//When the database becomes large (GBs), the following
		//commits a transaction to disk, which takes considerable time!
		//It is advised to then use multiple files in one program run.
		olaf_fp_db_destroy(db);
	}

	olaf_config_destroy(config);
	
	return 0;
}
