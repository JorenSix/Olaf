#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include <string.h>
#include <stdbool.h>

#include "olaf_stream_processor.h"
#include "olaf_runner.h"
#include "olaf_config.h"
#include "olaf_db.h"

void print_help(const char* message){
	fprintf(stderr,"%s",message);
	fprintf(stderr,"\tolaf_c [query audio.raw audio.wav | print audio.raw audio.wav |store [raw_audio.raw audio.wav]... | stats | name_to_id file_name.mp3 | delete raw_audio.raw audio.wav ]\n");
	exit(-10);
}

int main(int argc, const char* argv[]){

	if(argc < 2){
		print_help("No filename given\n");
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
		//print the hash an exit
		printf("%u\n",olaf_db_string_hash(argv[2],strlen(argv[2])));
		exit(0);
		return 0;
	} else if(strcmp(command,"stats") == 0){
		//print database statistics and exit
		Olaf_Config* config = olaf_config_default();
		Olaf_DB* db = olaf_db_new(config->dbFolder,true);
		olaf_db_stats(db,config->verbose);
		olaf_db_destroy(db);
		olaf_config_destroy(config);
		exit(0);
		return 0;
	}else {
		
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
