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

#include "olaf_cli_bridge.h"

#include "olaf_stream_processor.h"
#include "olaf_runner.h"
#include "olaf_config.h"
#include "olaf_db.h"
#include "olaf_fp_db_writer_cache.h"
#include "olaf_fp_matcher.h"


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

void olaf_has(Olaf_Config* config,size_t audio_identifiers_len,const char* audio_identifiers[], bool * has_audio_identifier){
	
	Olaf_DB* db = olaf_db_new(config->dbFolder,true);

	printf("audio file path; internal identifier; duration (s); fingerprints (#)\n");
	for(size_t arg_index = 0 ; arg_index < audio_identifiers_len ; arg_index++){
		// retrieve the audio identifier
		const char* audio_identifier = audio_identifiers[arg_index];
		// resolve the audio identifier to its on-disk numeric id
		uint32_t audio_id_num = olaf_db_identifier_id(audio_identifier,strlen(audio_identifier));
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


typedef struct {
    size_t q_index;
    size_t q_total;
    const char *query_path;
	float q_offset;
	uint32_t exclude_identifier; // when non-zero, drop matches with this id
} Olaf_Query_Print_Context;

static _Thread_local Olaf_Query_Print_Context olaf_query_print_context = {0};

/** A single accumulated match used by the JSON output path. */
typedef struct {
	int matchCount;
	float queryStart;
	float queryStop;
	char *path;
	uint32_t matchIdentifier;
	float referenceStart;
	float referenceStop;
} Olaf_JSON_Match;

typedef struct {
	Olaf_JSON_Match *items;
	size_t len;
	size_t cap;
} Olaf_JSON_Match_List;

static _Thread_local Olaf_JSON_Match_List olaf_json_matches = {0};

static void olaf_json_match_list_reset(Olaf_JSON_Match_List *list){
	for(size_t i = 0; i < list->len; i++){
		free(list->items[i].path);
	}
	list->len = 0;
}

static void olaf_json_match_list_push(Olaf_JSON_Match_List *list, const Olaf_JSON_Match *m){
	if(list->len == list->cap){
		size_t new_cap = list->cap == 0 ? 16 : list->cap * 2;
		Olaf_JSON_Match *resized = (Olaf_JSON_Match *) realloc(list->items, new_cap * sizeof(Olaf_JSON_Match));
		if(resized == NULL){
			fprintf(stderr,"Out of memory growing JSON match list.\n");
			return;
		}
		list->items = resized;
		list->cap = new_cap;
	}
	list->items[list->len] = *m;
	list->items[list->len].path = m->path ? strdup(m->path) : NULL;
	list->len++;
}

static void olaf_cli_collect_match(int matchCount,
                                    float queryStart,
                                    float queryStop,
                                    const char *path,
                                    uint32_t matchIdentifier,
                                    float referenceStart,
                                    float referenceStop){
	// Identity filter, mirroring the print path.
	if (olaf_query_print_context.exclude_identifier != 0
	    && matchCount > 0
	    && matchIdentifier == olaf_query_print_context.exclude_identifier) {
		return;
	}
	// Skip the synthetic "no results" sentinel (matchCount == 0). The JSON
	// emitter just produces an empty matches array if the list stays empty.
	if(matchCount == 0) return;

	Olaf_JSON_Match m = {
		.matchCount = matchCount,
		.queryStart = queryStart,
		.queryStop = queryStop,
		.path = (char *) path,
		.matchIdentifier = matchIdentifier,
		.referenceStart = referenceStart,
		.referenceStop = referenceStop,
	};
	olaf_json_match_list_push(&olaf_json_matches, &m);
}

/** Escape `s` for inclusion as a JSON string body. Writes to fp. */
static void json_print_escaped(FILE *fp, const char *s){
	if(s == NULL){
		fputs("\"\"", fp);
		return;
	}
	fputc('"', fp);
	for(const char *p = s; *p != '\0'; p++){
		unsigned char c = (unsigned char) *p;
		switch(c){
			case '"':  fputs("\\\"", fp); break;
			case '\\': fputs("\\\\", fp); break;
			case '\b': fputs("\\b", fp); break;
			case '\f': fputs("\\f", fp); break;
			case '\n': fputs("\\n", fp); break;
			case '\r': fputs("\\r", fp); break;
			case '\t': fputs("\\t", fp); break;
			default:
				if(c < 0x20){
					fprintf(fp, "\\u%04x", c);
				}else{
					fputc(c, fp);
				}
		}
	}
	fputc('"', fp);
}

static void olaf_cli_print_match(int matchCount,
                                 float queryStart,
                                 float queryStop,
                                 const char *path,
                                 uint32_t matchIdentifier,
                                 float referenceStart,
                                 float referenceStop) {
	// Filter self-matches when an exclude_identifier is set.
	// matchCount == 0 is the synthetic "no results" line; let it through
	// even when filtering, so callers still see an end-of-query marker.
	if (olaf_query_print_context.exclude_identifier != 0
	    && matchCount > 0
	    && matchIdentifier == olaf_query_print_context.exclude_identifier) {
		return;
	}

	// query info
	// "#{index} , #{total} , #{query} , #{query_offset} ,
    printf("%d ,%d ,%s, %.3f, ",
			(uint32_t)(olaf_query_print_context.q_index + 1),
			(uint32_t) olaf_query_print_context.q_total,
			olaf_query_print_context.query_path,
			olaf_query_print_context.q_offset);

	// match info
	// #{match_count} , #{query_start} , #{query_stop},
	printf("%d ,%.3f ,%.3f, ",
		   matchCount,
		   queryStart,
		   queryStop);

	printf("%s, %u, %.3f, %.3f\n",
		   path,
		   matchIdentifier,
		   referenceStart,
		   referenceStop);
}


void olaf_query(Olaf_Config* config, size_t q_index, size_t q_total, const char * query_path, const char* raw_audio_path, const char* audio_identifier, uint32_t exclude_identifier){
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
	Olaf_Runner * runner = olaf_runner_new(OLAF_RUNNER_MODE_QUERY, config, NULL,NULL);

	//create a new stream processor; NULL means the raw audio file could not be opened
	Olaf_Stream_Processor* processor = olaf_stream_processor_new(runner,raw_audio_path,audio_identifier);
	if(processor == NULL){
		olaf_runner_destroy(runner);
		return;
	}

	olaf_query_print_context.q_index = q_index;
    olaf_query_print_context.q_total = q_total;
    olaf_query_print_context.query_path = query_path;
	olaf_query_print_context.q_offset = 0.0f;
	olaf_query_print_context.exclude_identifier = exclude_identifier;

	Olaf_FP_Matcher_Result_Callback result_callback = olaf_cli_print_match;
	olaf_stream_processor_set_result_callback(processor, result_callback);
	olaf_stream_processor_set_result_header(processor, "query_index, total_queries, query_path, query_offset, match_count, query_start, query_stop, path, match_identifier, reference_start, reference_stop\n");


	//process the audio file
	olaf_stream_processor_process(processor);

	//destroy the stream processor
	olaf_stream_processor_destroy(processor);

	//destroy the runner
	olaf_runner_destroy(runner);
}

void olaf_query_json(Olaf_Config* config, size_t q_index, size_t q_total, const char * query_path, const char* raw_audio_path, const char* audio_identifier, uint32_t exclude_identifier){
	Olaf_DB* db = olaf_db_new(config->dbFolder,false);
	if(db == NULL){
		fprintf(stderr,"Error: Could not open database %s.\n",config->dbFolder);
		exit(-1);
		olaf_db_destroy(db);
		return;
	}
	olaf_db_destroy(db);

	Olaf_Runner * runner = olaf_runner_new(OLAF_RUNNER_MODE_QUERY, config, NULL,NULL);
	Olaf_Stream_Processor* processor = olaf_stream_processor_new(runner,raw_audio_path,audio_identifier);
	if(processor == NULL){
		olaf_runner_destroy(runner);
		return;
	}

	olaf_query_print_context.q_index = q_index;
	olaf_query_print_context.q_total = q_total;
	olaf_query_print_context.query_path = query_path;
	olaf_query_print_context.q_offset = 0.0f;
	olaf_query_print_context.exclude_identifier = exclude_identifier;

	// Reset & install the collector callback. Suppress the human-readable
	// summary line so the JSON document is the only thing on stdout/stderr
	// that downstream parsers need to handle.
	olaf_json_match_list_reset(&olaf_json_matches);
	olaf_stream_processor_set_result_callback(processor, olaf_cli_collect_match);
	olaf_stream_processor_set_result_header(processor, NULL);
	olaf_stream_processor_set_suppress_summary(processor, true);

	olaf_stream_processor_process(processor);

	double audio_duration = olaf_stream_processor_audio_duration(processor);
	double cpu_time_used = olaf_stream_processor_cpu_time(processor);
	size_t total_fp = olaf_stream_processor_total_fingerprints(processor);
	double fp_per_second = audio_duration > 0.0 ? (double) total_fp / audio_duration : 0.0;
	double realtime_factor = cpu_time_used > 0.0 ? audio_duration / cpu_time_used : 0.0;

	// Emit the JSON object. One object per query, no trailing newline so
	// callers that concatenate multiple queries see a stream of objects
	// they can pretty-print themselves.
	printf("{\n");
	printf("  \"query_index\": %zu,\n", q_index + 1);
	printf("  \"total_queries\": %zu,\n", q_total);
	printf("  \"query_path\": ");
	json_print_escaped(stdout, query_path);
	printf(",\n");
	printf("  \"query_offset\": %.3f,\n", 0.0);
	printf("  \"fingerprints_matched\": %zu,\n", total_fp);
	printf("  \"query_duration_seconds\": %.3f,\n", audio_duration);
	printf("  \"fingerprints_per_second\": %.3f,\n", fp_per_second);
	printf("  \"search_time_seconds\": %.3f,\n", cpu_time_used);
	printf("  \"realtime_factor\": %.3f,\n", realtime_factor);
	printf("  \"matches\": [");
	for(size_t i = 0; i < olaf_json_matches.len; i++){
		Olaf_JSON_Match *m = &olaf_json_matches.items[i];
		printf("%s\n    {\n", i == 0 ? "" : ",");
		printf("      \"match_count\": %d,\n", m->matchCount);
		printf("      \"query_start\": %.3f,\n", m->queryStart);
		printf("      \"query_stop\": %.3f,\n", m->queryStop);
		printf("      \"path\": ");
		json_print_escaped(stdout, m->path);
		printf(",\n");
		printf("      \"match_identifier\": %u,\n", m->matchIdentifier);
		printf("      \"reference_start\": %.3f,\n", m->referenceStart);
		printf("      \"reference_stop\": %.3f\n", m->referenceStop);
		printf("    }");
	}
	if(olaf_json_matches.len > 0) printf("\n  ");
	printf("]\n}\n");

	olaf_json_match_list_reset(&olaf_json_matches);

	olaf_stream_processor_destroy(processor);
	olaf_runner_destroy(runner);
}

void olaf_delete(Olaf_Config* config,const char* raw_audio_path, const char* audio_identifier){
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
	Olaf_Runner * runner = olaf_runner_new(OLAF_RUNNER_MODE_DELETE, config, NULL,NULL);

	//create a new stream processor; NULL means the raw audio file could not be opened
	Olaf_Stream_Processor* processor = olaf_stream_processor_new(runner,raw_audio_path,audio_identifier);
	if(processor == NULL){
		olaf_runner_destroy(runner);
		return;
	}

	//process the audio file
	olaf_stream_processor_process(processor);

	//destroy the stream processor
	olaf_stream_processor_destroy(processor);

	//destroy the runner
	olaf_runner_destroy(runner);
}

void olaf_print(Olaf_Config* config, const char* raw_audio_path, const char* audio_identifier){
	olaf_print_to_file(config, raw_audio_path, audio_identifier,stdout,stdout);
}

void olaf_print_to_file(Olaf_Config* config, const char* raw_audio_path, const char* audio_identifier,FILE * fp_cache_file,FILE * fp_meta_file){
	//print fingerprints to stdout (no database needed for PRINT mode)

	//create a new runner in PRINT mode
	Olaf_Runner * runner = olaf_runner_new(OLAF_RUNNER_MODE_CACHE, config, fp_cache_file,fp_meta_file);
	//create a new stream processor; NULL means the raw audio file could not be opened
	Olaf_Stream_Processor* processor = olaf_stream_processor_new(runner,raw_audio_path,audio_identifier);
	if(processor == NULL){
		olaf_runner_destroy(runner);
		return;
	}

	//process the audio file (this will print to stdout)
	olaf_stream_processor_process(processor);

	//destroy the stream processor
	olaf_stream_processor_destroy(processor);

	//destroy the runner
	olaf_runner_destroy(runner);
}

uint32_t olaf_name_to_id(const char* audio_identifier){
	return olaf_db_identifier_id(audio_identifier,strlen(audio_identifier));
}

void olaf_store(Olaf_Config* config, const char* raw_audio_path, const char* orig_audio_path){
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

	//printf("Storing audio file '%s' with original path '%s' in database '%s'\n",raw_audio_path,orig_audio_path,config->dbFolder);
	
	
	//create a new runner
	Olaf_Runner * runner = olaf_runner_new(OLAF_RUNNER_MODE_STORE, config, NULL,NULL);

	//create a new stream processor; NULL means the raw audio file could not be opened
	Olaf_Stream_Processor* processor = olaf_stream_processor_new(runner,raw_audio_path,orig_audio_path);
	if(processor == NULL){
		olaf_runner_destroy(runner);
		return;
	}

	//process the audio file
	olaf_stream_processor_process(processor);

	//destroy the stream processor
	olaf_stream_processor_destroy(processor);

	//destroy the runner
	olaf_runner_destroy(runner);


}

int olaf_main(int argc, const char* argv[]){

	Olaf_Config* config = olaf_config_default();

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
		//print the on-disk numeric id and exit
		printf("%u\n",olaf_db_identifier_id(argv[2],strlen(argv[2])));
		exit(0);
		return 0;
	} else if(strcmp(command,"stats") == 0){
		fprintf(stderr,"%s Usupported stats: \n",command);
	} else if(strcmp(command,"store_cached") == 0){
		olaf_store_cached(argc,argv);
	} else {
		fprintf(stderr,"%s Unknown command: \n",command);
	}

	Olaf_Runner * runner = olaf_runner_new(runner_mode,config, NULL,NULL);

	if(runner_mode == OLAF_RUNNER_MODE_QUERY && argc == 2){
		//read audio samples from standard input
		runner->config->printResultEvery = 3;//print results every three seconds
		runner->config->keepMatchesFor = 10;//keep matches for 7 seconds
		fprintf(stderr,"Start listening for incoming raw audio samples piped in over STDIN.\n");
		Olaf_Stream_Processor* processor = olaf_stream_processor_new(runner,NULL,"stdin");
		if(processor != NULL){
			olaf_stream_processor_process(processor);
			olaf_stream_processor_destroy(processor);
		}
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
			if(processor == NULL){
				continue;
			}
			olaf_stream_processor_process(processor);
			olaf_stream_processor_destroy(processor);
		}
	}

	olaf_runner_destroy(runner);

	return 0;
}