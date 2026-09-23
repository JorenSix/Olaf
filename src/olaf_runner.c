#include "olaf_config.h"
#include "olaf_config_internal.h"
#include "olaf_runner.h"

#include "pffft.h"
#include "assert.h"

Olaf_Runner * olaf_runner_new(int mode, Olaf_Config * config, FILE * fp_cache_file, FILE * fp_meta_file){
	if(!olaf_config_check(olaf_config_error(config))) return NULL;
	Olaf_Runner *runner = (Olaf_Runner *) calloc(1, sizeof(Olaf_Runner));
	if(runner == NULL){ errno = ENOMEM; return NULL; }

	runner->mode = mode;
	runner->config =  config;
	runner->fp_cache_file = fp_cache_file;
	runner->fp_meta_file = fp_meta_file;
	
	//The raw format and size of float should be 32 bits
	assert(runner->config->bytesPerAudioSample == sizeof(float));

	//the samples should be a 32bit float
	int bytesPerAudioBlock = runner->config->audioBlockSize * runner->config->bytesPerAudioSample;
	//initialize the pfft object
	// We will use a size of audioblocksize 
	// We are only interested in real part
	runner->fftSetup = pffft_new_setup(runner->config->audioBlockSize,PFFFT_REAL);
	runner->fft_in = (float *) pffft_aligned_malloc(bytesPerAudioBlock);//fft input
	runner->fft_out= (float *) pffft_aligned_malloc(bytesPerAudioBlock);//fft output

	if(!runner->fftSetup || !runner->fft_in || !runner->fft_out){
		olaf_runner_destroy(runner);
		errno = ENOMEM;
		return NULL;
	}

	//no db needed in print mode!
	if(mode == OLAF_RUNNER_MODE_PRINT || mode == OLAF_RUNNER_MODE_CACHE){
		runner->db = NULL;
		if(runner->config->verbose){
			fprintf(stderr, "No DB needed in PRINT or CACHE mode\n");
		}
	} else {
		bool readonly_db = (mode == OLAF_RUNNER_MODE_QUERY);
		if(runner->config->verbose){
			fprintf(stderr, "Open DB at in readonly mode %d folder '%s'\n", readonly_db, runner->config->dbFolder);
		}
		runner->db = olaf_db_new(runner->config->dbFolder,readonly_db);
	}
	
	return runner;
}

void olaf_runner_destroy(Olaf_Runner * runner){
	if(runner == NULL) return;

	//cleanup fft structures
	pffft_aligned_free(runner->fft_in);
	pffft_aligned_free(runner->fft_out);
	
	if(runner->fftSetup) pffft_destroy_setup(runner->fftSetup);

	if(runner->db!= NULL){
		//When the database becomes large (GBs), the following
		//commits a transaction to disk, which takes considerable time!
		//It is advised to then use multiple files in one program run.
		olaf_db_destroy(runner->db);
	}

	//olaf_config_destroy(runner->config);


	free(runner);
}
