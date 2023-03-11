#include <time.h>
#include <libgen.h>
#include <inttypes.h>
#include <assert.h>

#include "pffft.h"

#include "olaf_stream_processor.h"
#include "olaf_runner.h"
#include "olaf_window.h"
#include "olaf_config.h"
#include "olaf_reader.h"
#include "olaf_ep_extractor.h"
#include "olaf_fp_extractor.h"
#include "olaf_db.h"
#include "olaf_fp_matcher.h"
#include "olaf_fp_db_writer.h"
#include "olaf_fp_file_writer.h"

struct Olaf_Stream_Processor{
	Olaf_Runner *runner;
	Olaf_Config *config;
	Olaf_Reader *reader;
	Olaf_EP_Extractor *ep_extractor;
	Olaf_FP_Extractor *fp_extractor;

	uint32_t audio_identifier;
	const char* orig_path;

	//Input audio samples
	float *audio_data;
};


Olaf_Stream_Processor * olaf_stream_processor_new(Olaf_Runner * runner,const char* raw_path,const char* orig_path){

	Olaf_Stream_Processor * processor = (Olaf_Stream_Processor *) malloc(sizeof(Olaf_Stream_Processor));

	processor->orig_path = orig_path;
	processor->audio_identifier = 0;
	if(orig_path!=NULL)
		processor->audio_identifier = olaf_db_string_hash(orig_path,strlen(orig_path));

	processor->runner = runner;
	processor->config = runner->config;
	processor->ep_extractor = olaf_ep_extractor_new(processor->config);
	processor->fp_extractor = olaf_fp_extractor_new(processor->config);
	processor->reader = olaf_reader_new(processor->config,raw_path);
	processor->audio_data = (float *) calloc(processor->config->audioBlockSize , sizeof(float)); //Input audio samples
	
	return processor;
}

void olaf_stream_processor_destroy(Olaf_Stream_Processor * processor){
	olaf_reader_destroy(processor->reader);
	olaf_fp_extractor_destroy(processor->fp_extractor);
	olaf_ep_extractor_destroy(processor->ep_extractor);
	
	free(processor->audio_data);
	free(processor);
}

void olaf_stream_processor_process(Olaf_Stream_Processor * processor){
	
	int audioBlockIndex = 0;

	Olaf_FP_DB_Writer *fp_db_writer = NULL;
	Olaf_FP_Matcher *fp_matcher = NULL;


	if(processor->runner->mode == OLAF_RUNNER_MODE_QUERY ){
		fp_matcher = olaf_fp_matcher_new(processor->config,processor->runner->db);
	} else if(processor->runner->mode == OLAF_RUNNER_MODE_STORE || processor->runner->mode == OLAF_RUNNER_MODE_DELETE){
		fp_db_writer = olaf_fp_db_writer_new(processor->runner->db,processor->audio_identifier);
	}else if(processor->runner->mode == OLAF_RUNNER_MODE_PRINT ){
		fp_db_writer = NULL;
	}

	struct extracted_event_points * eventPoints = NULL;
	struct extracted_fingerprints * fingerprints = NULL;

	size_t samples_read = olaf_reader_read(processor->reader,processor->audio_data);
	size_t samples_expected = processor->config->audioStepSize;

	clock_t start, end;
    double cpu_time_used;
    start = clock();

    //The fft struct is reused
	PFFFT_Setup *fftSetup = processor->runner->fftSetup;
	float *fft_in= processor->runner->fft_in;
	float *fft_out= processor->runner->fft_out;

	const float* window = olaf_fft_window(processor->config->audioBlockSize);
	while(samples_read==samples_expected){
		samples_read = olaf_reader_read(processor->reader,processor->audio_data);
		
		// windowing + copy to fft input
		for(int j = 0 ; j <  processor->config->audioBlockSize ; j++){
			fft_in[j] = processor->audio_data[j] * window[j];
		}

		//do the transform
		pffft_transform_ordered(fftSetup, fft_in, fft_out, 0, PFFFT_FORWARD);

		//extract event points
		eventPoints = olaf_ep_extractor_extract(processor->ep_extractor,fft_out,audioBlockIndex);

		//if there are enough event points
		if(eventPoints->eventPointIndex > processor->config->eventPointThreshold){
			//combine the event points into fingerprints
			fingerprints = olaf_fp_extractor_extract(processor->fp_extractor,eventPoints,audioBlockIndex);

			if(processor->runner->mode == OLAF_RUNNER_MODE_QUERY){
				//use the fingerprints to match with the reference database
				//report matches if found
				olaf_fp_matcher_match(fp_matcher,fingerprints);
			}else if(processor->runner->mode == OLAF_RUNNER_MODE_STORE){
				//use the fp's to store in the db
				olaf_fp_db_writer_store(fp_db_writer,fingerprints);
			} else if(processor->runner->mode == OLAF_RUNNER_MODE_DELETE){
				olaf_fp_db_writer_delete(fp_db_writer,fingerprints);
			} else if(processor->runner->mode == OLAF_RUNNER_MODE_PRINT){
				for(size_t i = 0 ; i < fingerprints->fingerprintIndex ; i++ ){
					struct fingerprint f = fingerprints->fingerprints[i];
					printf("%" PRIu64 ", ", olaf_fp_extractor_hash(f));
					printf("%d, %d, %.6f, ", f.timeIndex1,f.frequencyBin1,f.magnitude1);
					printf("%d, %d, %.6f, ", f.timeIndex2,f.frequencyBin2,f.magnitude2);
					printf("%d, %d, %.6f\n", f.timeIndex3,f.frequencyBin3,f.magnitude3);
				}
			}

			//handled all fingerprints set index back to zero

			fingerprints->fingerprintIndex = 0;
		}
		//increase the audio buffer counter
		audioBlockIndex++;

		//report some info for the streaming case
		if(audioBlockIndex % 100 == 0 && strcmp(processor->orig_path , "stdin") == 0){
			double audioDuration = (double) olaf_reader_total_samples_read(processor->reader) / (double) processor->config->audioSampleRate;
			fprintf(stderr,"Time: %.3fs  fps: %zu \n",audioDuration,olaf_fp_extractor_total(processor->fp_extractor));
		}
	}
	
	//handle the last event points
	fingerprints = olaf_fp_extractor_extract(processor->fp_extractor,eventPoints,audioBlockIndex);
	double audioDuration = (double) olaf_reader_total_samples_read(processor->reader) / (double) processor->config->audioSampleRate;

	if(processor->runner->mode == OLAF_RUNNER_MODE_QUERY){
		//use the fingerprints to match with the reference database
		//report matches if found
		olaf_fp_matcher_match(fp_matcher,fingerprints);
		olaf_fp_matcher_print_header();
		olaf_fp_matcher_print_results(fp_matcher);
		olaf_fp_matcher_destroy(fp_matcher);
	}else if(processor->runner->mode == OLAF_RUNNER_MODE_STORE){
		//use the fp's to store in the db
		olaf_fp_db_writer_store(fp_db_writer,fingerprints);
		olaf_fp_db_writer_destroy(fp_db_writer,true);
		Olaf_Resource_Meta_data meta_data;
		meta_data.duration = (float) audioDuration;
		if(processor->orig_path == NULL){
			fprintf(stderr,"Original path is NULL, please add the parameter");
		}else{
			strcpy(meta_data.path,processor->orig_path);
		}
		meta_data.fingerprints = olaf_fp_extractor_total(processor->fp_extractor);
		olaf_db_store_meta_data(processor->runner->db,&processor->audio_identifier,&meta_data);
	} else if(processor->runner->mode == OLAF_RUNNER_MODE_DELETE){
		olaf_fp_db_writer_delete(fp_db_writer,fingerprints);
		olaf_fp_db_writer_destroy(fp_db_writer,false);
		olaf_db_delete_meta_data(processor->runner->db,&processor->audio_identifier);
	} else if(processor->runner->mode == OLAF_RUNNER_MODE_PRINT){
		for(size_t i = 0 ; i < fingerprints->fingerprintIndex ; i++ ){
			struct fingerprint f = fingerprints->fingerprints[i];
			printf("%"PRIu64 ", ", olaf_fp_extractor_hash(f));
			printf("%d, %d, %.6f, ", f.timeIndex1,f.frequencyBin1,f.magnitude1);
			printf("%d, %d, %.6f, ", f.timeIndex2,f.frequencyBin2,f.magnitude2);
			printf("%d, %d, %.6f\n", f.timeIndex3,f.frequencyBin3,f.magnitude3);
		}
	}

	//for timing statistics
	end = clock();
    cpu_time_used = ((double) (end - start)) / CLOCKS_PER_SEC;
    double ratio = audioDuration / cpu_time_used;

	const char* verb = "Processed";
	if(processor->runner->mode == OLAF_RUNNER_MODE_STORE){
		verb = "Stored";
	} else if(processor->runner->mode == OLAF_RUNNER_MODE_QUERY){
		verb = "Matched";
	}else if(processor->runner->mode == OLAF_RUNNER_MODE_DELETE){
		verb = "Deleted";
	}
	double fingerprintspersecond = olaf_fp_extractor_total(processor->fp_extractor) / audioDuration;
    fprintf(stderr,"%s %lu fp's from %.1fs (%.0f fp/s) in %.3fs (%.0f times realtime)\n",verb,olaf_fp_extractor_total(processor->fp_extractor), audioDuration,fingerprintspersecond,cpu_time_used,ratio);
}
