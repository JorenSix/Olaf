#include "olaf_config.h"
#include "olaf_runner.h"

#include "pffft.h"
#include "assert.h"

Olaf_Runner * olaf_runner_new(int mode){
	Olaf_Runner *runner = (Olaf_Runner *) malloc(sizeof(Olaf_Runner));

	runner->mode = mode;
	//Get the default configuration
	#ifdef mem
		fprintf(stderr,"Info: using the mem configuration\n");
		runner->config = olaf_config_mem();
	#else
		runner->config = olaf_config_default();
	#endif
	
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

	
	if(runner->config->verbose){
		fprintf(stderr, "Open DB at folder '%s'\n", runner->config->dbFolder);
	}

	//no db needed in print mode!
	if(mode == OLAF_RUNNER_MODE_PRINT){
		runner->db = NULL;
	} else {
		bool readonly_db = (mode == OLAF_RUNNER_MODE_QUERY);
		runner->db = olaf_db_new(runner->config->dbFolder,readonly_db);
	}
	
	return runner;
}

void olaf_runner_destroy(Olaf_Runner * runner){	

	//cleanup fft structures
	pffft_aligned_free(runner->fft_in);
	pffft_aligned_free(runner->fft_out);
	
	pffft_destroy_setup(runner->fftSetup);

	if(runner->db!= NULL){
		//When the database becomes large (GBs), the following
		//commits a transaction to disk, which takes considerable time!
		//It is advised to then use multiple files in one program run.
		olaf_db_destroy(runner->db);
	}

	olaf_config_destroy(runner->config);

	free(runner);
}
