/** @file olaf.c
 * @brief OLAF
 *
 * @mainpage	Overly Lightweight Acoustic Fingerprinting (Olaf)
 *
 * @section intro_sec Introduction
 * Olaf is a C application / library for landmark based acoustic fingerprinting. 
 * Olaf is able to extract fingerprints from an audio stream, and either store those 
 * fingerprints in a database, or find a match between extracted fingerprints and 
 * stored fingerprints. Olaf does this efficiently in order to be used on embedded platforms, 
 * traditional computers or in web browsers via WASM.
 *
 * Please be aware of the patents US7627477 B2 and US6990453 and perhaps others. They describe 
 * techniques used in algorithms implemented within Olaf. These patents limit the use of Olaf 
 * under various conditions and for several regions. Please make sure to consult your intellectual 
 * property rights specialist if you are in doubt about these restrictions. If these restrictions apply, 
 * please respect the patent holders rights. The main aim of Olaf is to serve as a learning platform 
 * on efficient (embedded) acoustic fingerprinting algorithms.
 * 
 * 
 * @section why_sec Why Olaf?
 * 
 * Olaf stands out for three reasons. 
 * 1. Olaf runs on embedded devices. 
 * 2. Olaf is fast on traditional computers. 
 * 3. Olaf runs in the browsers.
 * 
 * There seem to be no lightweight acoustic fingerprinting libraries that are straightforward 
 * to run on embedded platforms. On embedded platforms memory and computational resources are severely limited. 
 * Olaf is written in portable C with these restrictions in mind. Olaf mainly targets 32-bit ARM devices such as 
 * some Teensy’s, some Arduino’s and the ESP32. Other modern embedded platforms with similar specifications and 
 * might work as well.
 * 
 * Olaf, being written in portable C, operates also on traditional computers. There, the efficiency of Olaf makes 
 * it run fast. On embedded devices reference fingerprints are stored in memory. On traditional computers 
 * fingerprints are stored in a high-performance key-value-store: LMDB. LMDB offers an a B+-tree based persistent 
 * storage ideal for small keys and values with low storage overhead.
 * 
 * Olaf works in the browser. Via Emscripten Olaf can be compiled to WASM. This makes it relatively 
 * straightforward to combine the capabilities of the Web Audio API and Olaf to create browser based audio 
 * fingerprinting applications.
 * 
 * @section design Olaf's design
 * 
 * The core of Olaf is kept as small as possible and is shared between the ESP32, WebAssembly and 
 * traditional version. The only difference is how audio enters the system. The default 
 * configuration expects monophonic, 32bit float audio sampled at 16kHz. Transcoding and resampling is different
 * for each environment.  
 * 
 * For traditional computers file handling and transcoding is governed by a Ruby script. 
 * This script expands lists of incoming audio files, transcodes audio files, checks incoming audio,
 * checks for duplicate material, validates arguments and input,... The Ruby script, essentially, 
 * makes Olaf an easy to use CLI application and keeps the C parts of Olaf simple. The C core it is 
 * not concerned with e.g. transcoding. Crucially, the C core trusts input and does not do much input
 * validation and does not provide much guardrails. Since the interface is the Ruby script this 
 * seems warranted.
 *
 * For the ESP32 version, only a small part of the core is used. To create a new ESP32 Arduino project, there is a 
 * small script which links to the core. The default Arduino setup uses C++ extensions so olaf_config.h 
 * remains olaf_config.h 
 * but `olaf_config.c` becomes `olaf_config.cpp`. Perhaps other environments ([PlatformIO](https://platformio.org/ "PlatformIO")) do not need this name change.
 * 
 * The WebAssembly version also uses a similarly small part of the core and some bridge code is available.
 * 
 * To verify both the ESP32 and WebAssembly versions, the Olaf C core can be compiled with the
 * 'memory' database to mimic the ESP32/WebAssembly versions. In the compilation step the implementation for
 * the `olaf_db.h` header is done by `olaf_db_mem.c` in stead of the standard `olaf_db.c` implementation. This
 * paradigm of several implementations for a single header file is done a few times in Olaf. Olaf ships with several
 * max-filter implementations.
 * 
 * @section configuration Olaf's configuration
 * 
 * The configuration of Olaf is set at compile time, since it is expected to not change
 * in between runs. The default configuration is defined in the function olaf_config_default() in 
 * olaf_config.h. A different set of default configuration parameters is available for the 
 * memory version, ESP32 version (e.g.  olaf_config_esp_32()) and the WebAssembly version.   
 * 
 * @secreflist
 * 
 **/

#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include <string.h>
#include <stdbool.h>
#include <stdint.h>

#include "olaf_wrapper_bridge.h"

#include "olaf_stream_processor.h"
#include "olaf_runner.h"
#include "olaf_config.h"
#include "olaf_db.h"
#include "olaf_fp_db_writer_cache.h"


Olaf_Config* olaf_default_config(){
	//return the default configuration
	Olaf_Config* config = olaf_config_default();
	if(config == NULL){
		fprintf(stderr,"Error: Could not allocate memory for the default configuration.\n");
		exit(-1);
	}
	return config;
}

int olaf_stats(const Olaf_Config* config){
	size_t folder_len = strlen(config->dbFolder);

	//TODO fix for Windows
	if(folder_len > 0 && config->dbFolder[folder_len - 1] != '/'){
		fprintf(stderr, "Error printing stats: Database folder '%s' must end with '/'\n", config->dbFolder);
		return -1;
	}
	// else
	Olaf_DB* db = olaf_db_new(config->dbFolder,true);
	olaf_db_stats(db,config->verbose);
	olaf_db_destroy(db);
	return 0;
}

void olaf_has(const Olaf_Config* config,size_t audio_identifiers_len,const char* audio_identifiers[], bool * has_audio_identifier){
	
	Olaf_DB* db = olaf_db_new(config->dbFolder,true);

	printf("audio file path; internal identifier; duration (s); fingerprints (#)\n");
	for(size_t arg_index = 0 ; arg_index < audio_identifiers_len ; arg_index++){
		// retrieve the audio identifier
		const char* audio_identifier = audio_identifiers[arg_index];
		// make a numeric hash of the audio identifier
		uint32_t audio_id_num = olaf_db_string_hash(audio_identifier,strlen(audio_identifier));
		bool found_id = olaf_db_has_meta_data(db,&audio_id_num);
		if(found_id) {
			Olaf_Resource_Meta_data e;
			olaf_db_find_meta_data(db,&audio_id_num,&e);
			printf("%s;%u;%.3f;%ld\n",audio_identifier,audio_id_num,e.duration,e.fingerprints);
			
		}else{
			printf("%s;;;\n",audio_identifier);
		}
		if(has_audio_identifier != NULL){
			has_audio_identifier[arg_index] = found_id; 
		}
	}
	olaf_db_destroy(db);
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

void olaf_query(const Olaf_Config* config, const char* raw_audio_path, const char* audio_identifier){
	//store the fingerprints in the database
	Olaf_DB* db = olaf_db_new(config->dbFolder,false);
	if(db == NULL){
		fprintf(stderr,"Error: Could not open database %s.\n",config->dbFolder);
		exit(-1);
		//close the database
		olaf_db_destroy(db);
		return;
	}
	//close the database
	olaf_db_destroy(db);
	

	//create a new runner
	Olaf_Runner * runner = olaf_runner_new(OLAF_RUNNER_MODE_QUERY, config);
	
	//create a new stream processor
	Olaf_Stream_Processor* processor = olaf_stream_processor_new(runner,raw_audio_path,audio_identifier);
	
	//process the audio file
	olaf_stream_processor_process(processor);
	
	//destroy the stream processor
	olaf_stream_processor_destroy(processor);

	//destroy the runner
	olaf_runner_destroy(runner);
}

void olaf_delete(const Olaf_Config* config,const char* raw_audio_path, const char* audio_identifier){
	//store the fingerprints in the database
	Olaf_DB* db = olaf_db_new(config->dbFolder,true);
	if(db == NULL){
		fprintf(stderr,"Error: Could not open database %s.\n",config->dbFolder);
		exit(-1);
		//close the database
		olaf_db_destroy(db);
		return;
	}
	//close the database
	olaf_db_destroy(db);
	

	//create a new runner
	Olaf_Runner * runner = olaf_runner_new(OLAF_RUNNER_MODE_DELETE, config);
	
	//create a new stream processor
	Olaf_Stream_Processor* processor = olaf_stream_processor_new(runner,raw_audio_path,audio_identifier);
	
	//process the audio file
	olaf_stream_processor_process(processor);
	
	//destroy the stream processor
	olaf_stream_processor_destroy(processor);

	//destroy the runner
	olaf_runner_destroy(runner);
}


void olaf_store(const Olaf_Config* config, const char* raw_audio_path, const char* audio_identifier){
	//store the fingerprints in the database
	Olaf_DB* db = olaf_db_new(config->dbFolder,false);
	if(db == NULL){
		fprintf(stderr,"Error: Could not open database %s.\n",config->dbFolder);
		//close the database
		olaf_db_destroy(db);
		exit(-1);
	}
	//close the database
	olaf_db_destroy(db);
	
	
	//create a new runner
	Olaf_Runner * runner = olaf_runner_new(OLAF_RUNNER_MODE_STORE, config);
	
	//create a new stream processor
	Olaf_Stream_Processor* processor = olaf_stream_processor_new(runner,raw_audio_path,audio_identifier);
	
	//process the audio file
	olaf_stream_processor_process(processor);
	
	//destroy the stream processor
	olaf_stream_processor_destroy(processor);

	//destroy the runner
	olaf_runner_destroy(runner);
	
	
}

int olaf_main(int argc, const char* argv[]){

	const Olaf_Config* config = olaf_config_default();

	const char* command = argv[1];
	int runner_mode = OLAF_RUNNER_MODE_QUERY; 
	
	if(strcmp(command,"store") == 0){
		runner_mode = OLAF_RUNNER_MODE_STORE;
	} else if(strcmp(command,"query") == 0){
		runner_mode = OLAF_RUNNER_MODE_QUERY;
	} else if(strcmp(command,"delete") == 0){
		runner_mode = OLAF_RUNNER_MODE_DELETE;
	} else if(strcmp(command,"print") == 0){
		runner_mode = OLAF_RUNNER_MODE_PRINT;
	} else if(strcmp(command,"name_to_id") == 0){
		//print the hash and exit
		printf("%u\n",olaf_db_string_hash(argv[2],strlen(argv[2])));
		exit(0);
		return 0;
	} else if(strcmp(command,"stats") == 0){
		fprintf(stderr,"%s Usupported stats: \n",command);
	} else if(strcmp(command,"store_cached") == 0){
		olaf_store_cached(argc,argv);
	} else {
		fprintf(stderr,"%s Unknown command: \n",command);
	}

	Olaf_Runner * runner = olaf_runner_new(runner_mode,config);

	if(runner_mode == OLAF_RUNNER_MODE_QUERY && argc == 2){
		//read audio samples from standard input
		runner->config->printResultEvery = 3;//print results every three seconds
		runner->config->keepMatchesFor = 10;//keep matches for 7 seconds
		fprintf(stderr,"Start listening for incoming raw audio samples piped in over STDIN.\n");
		Olaf_Stream_Processor* processor = olaf_stream_processor_new(runner,NULL,"stdin");
		olaf_stream_processor_process(processor);
		olaf_stream_processor_destroy(processor);
	}else{
		if(argc % 2 == 1 ){
			fprintf(stderr,"Error: You need to provide converted raw audio and the original file name, for example:\n\tolaf query audio.raw original_filename.mp3\n");
			exit(-3);	
		}
		//for each audio file
		for(int arg_index = 2 ; arg_index + 1 < argc ; arg_index+=2){
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