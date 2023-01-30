#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include <string.h>
#include <stdbool.h>

#include "olaf_stream_processor.h"
#include "olaf_runner.h"
#include "olaf_config.h"
#include "olaf_db.h"
#include "olaf_fp_db_writer_cache.h"

void olaf_print_help(const char* message){
	fprintf(stderr,"%s",message);
	fprintf(stderr,"\tolaf_c [query audio.raw audio.wav | print audio.raw audio.wav |store [raw_audio.raw audio.wav]... | stats | name_to_id file_name.mp3 | delete raw_audio.raw audio.wav ]\n");
	exit(-10);
}

int olaf_stats(){
	//print database statistics and exit
	Olaf_Config* config = olaf_config_default();
	Olaf_DB* db = olaf_db_new(config->dbFolder,true);
	olaf_db_stats(db,config->verbose);
	olaf_db_destroy(db);
	olaf_config_destroy(config);
	exit(0);
	return 0;
}

int olaf_has(int argc, const char* argv[]){
	Olaf_Config* config = olaf_config_default();
	Olaf_DB* db = olaf_db_new(config->dbFolder,true);
	printf("audio file path; internal identifier; duration (s); fingerprints (#)\n");
	for(int arg_index = 2 ; arg_index < argc ; arg_index++){
		const char* orig_path = argv[arg_index];
		uint32_t audio_id = olaf_db_string_hash(orig_path,strlen(orig_path));
		if(olaf_db_has_meta_data(db,&audio_id)){
			Olaf_Resource_Meta_data e;
			olaf_db_find_meta_data(db,&audio_id,&e);
			printf("%s;%u;%.3f;%ld\n",orig_path,audio_id,e.duration,e.fingerprints);
		}else{
			printf("%s;;;\n",orig_path);
		}
	}
	olaf_db_destroy(db);
	olaf_config_destroy(config);
	exit(0);
	return 0;
}

int olaf_store_cached(int argc, const char* argv[]){
	Olaf_Config* config = olaf_config_default();
	Olaf_DB* db = olaf_db_new(config->dbFolder,false);

	for(int arg_index = 2 ; arg_index < argc ; arg_index++){
		const char* csv_filename = argv[arg_index];
		Olaf_FP_DB_Writer_Cache * cache_writer  = olaf_fp_db_writer_cache_new(db,config,csv_filename);
		olaf_fp_db_writer_cache_store(cache_writer);
		olaf_fp_db_writer_cache_destroy(cache_writer);
	}
	olaf_db_destroy(db);
	olaf_config_destroy(config);
	exit(0);
	return 0;
}

int main(int argc, const char* argv[]){

	if(argc < 2){
		olaf_print_help("No filename given\n");
	}

	const char* command = argv[1];
	enum Olaf_Command cmd = query; 
	
	if(strcmp(command,"store") == 0){
		cmd = store;
	} else if(strcmp(command,"query") == 0){
		cmd = query;
	} else if(strcmp(command,"delete") == 0){
		cmd = delete;
	} else if(strcmp(command,"print") == 0){
		cmd = print;
	} else if(strcmp(command,"name_to_id") == 0){
		//print the hash and exit
		printf("%u\n",olaf_db_string_hash(argv[2],strlen(argv[2])));
		exit(0);
		return 0;
	} else if(strcmp(command,"stats") == 0){
		olaf_stats();
	} else if(strcmp(command,"has") == 0){
		olaf_has(argc,argv);
	} else if(strcmp(command,"store_cached") == 0){
		olaf_store_cached(argc,argv);
	} else {
		fprintf(stderr,"%s Unkown command: \n",command);
		olaf_print_help("Unkonwn command\n");
	}

	Olaf_Runner * runner = olaf_runner_new(cmd);

	if(cmd == query && argc == 2){
		//read audio samples from standard input
		runner->config->printResultEvery = 3;//print results every three seconds
		runner->config->keepMatchesFor = 10;//keep matches for 7 seconds

		Olaf_Stream_Processor* processor = olaf_stream_processor_new(runner,NULL,"stdin");
		olaf_stream_processor_process(processor);
		olaf_stream_processor_destroy(processor);
	}else{
		//for each audio file
		for(int arg_index = 2 ; arg_index < argc ; arg_index+=2){
			const char* raw_path =  argv[arg_index];
			const char* orig_path = argv[arg_index + 1];
			Olaf_Stream_Processor* processor = olaf_stream_processor_new(runner,raw_path,orig_path);
			olaf_stream_processor_process(processor);
			olaf_stream_processor_destroy(processor);
		}
	}

	olaf_runner_destroy(runner);

	return 0;
}
