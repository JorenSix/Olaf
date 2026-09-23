#include <time.h>
#include <libgen.h>
#include <inttypes.h>
#include <assert.h>

#include "pffft.h"

#include "olaf_stream_processor.h"
#include "olaf_runner.h"
#include "olaf_window.h"
#include "olaf_config.h"
#include "olaf_config_internal.h"
#include "olaf_fp_matcher_internal.h"
#include "olaf_reader.h"
#include "olaf_ep_extractor.h"
#include "olaf_fp_extractor.h"
#include "olaf_db.h"
#include "olaf_fp_matcher.h"
#include "olaf_fp_db_writer.h"
#include "olaf_fp_file_writer.h"

struct Olaf_Stream_Processor{
	Olaf_Runner *runner; /**< Reference to the runner managing this processor */
	Olaf_Config *config; /**< Reference to the Olaf configuration */
	Olaf_Reader *reader; /**< Audio reader for the input stream */
	Olaf_EP_Extractor *ep_extractor; /**< Event point extractor instance */
	Olaf_FP_Matcher *fp_matcher;
	Olaf_FP_Extractor *fp_extractor; /**< Fingerprint extractor instance */

	uint32_t audio_identifier; /**< Hash identifier for the audio file */
	const char* orig_path; /**< Original file path of the audio source */


	//Input audio samples
	float *audio_data; /**< Buffer holding input audio samples */

	//Stats captured at end of process(); accessible via accessors below.
	double last_audio_duration; /**< Total audio duration in seconds. */
	double last_cpu_time_used; /**< CPU time spent in process() in seconds. */
	size_t last_total_fingerprints; /**< Total fingerprints extracted/matched. */
	bool suppress_summary_print; /**< If true, skip the summary line on stderr. */
};


Olaf_Stream_Processor * olaf_stream_processor_new(Olaf_Runner * runner,const char* raw_path,const char* orig_path){

	if(!olaf_config_check(runner ? olaf_config_error(runner->config) : "runner must not be NULL")) return NULL;
	Olaf_Stream_Processor * processor = (Olaf_Stream_Processor *) calloc(1, sizeof(Olaf_Stream_Processor));
	if(processor == NULL){ errno = ENOMEM; return NULL; }

	processor->orig_path = orig_path;
	processor->audio_identifier = 0;
	if(orig_path!=NULL)
		processor->audio_identifier = olaf_db_identifier_id(orig_path,strlen(orig_path));

	processor->last_audio_duration = 0.0;
	processor->last_cpu_time_used = 0.0;
	processor->last_total_fingerprints = 0;
	processor->suppress_summary_print = false;

	processor->runner = runner;
	processor->config = runner->config;
	processor->ep_extractor = olaf_ep_extractor_new(processor->config);
	if(!processor->ep_extractor) goto failed;
	processor->fp_extractor = olaf_fp_extractor_new(processor->config);
	if(!processor->fp_extractor) goto failed;
	processor->audio_data = (float *) calloc(processor->config->audioBlockSize , sizeof(float)); //Input audio samples

	if(!processor->audio_data){ errno = ENOMEM; goto failed; }
	if(runner->mode == OLAF_RUNNER_MODE_QUERY){
		processor->fp_matcher = olaf_fp_matcher_new(processor->config, runner->db, olaf_fp_matcher_callback_print_result);
		if(!processor->fp_matcher) goto failed;
	}
	processor->reader = olaf_reader_new(runner->config, raw_path);
	if(!processor->reader) goto failed;
	return processor;

failed: {
	int error = errno;
	olaf_stream_processor_destroy(processor);
	errno = error;
	return NULL;
}

}

void olaf_stream_processor_destroy(Olaf_Stream_Processor * processor){
	if(processor == NULL) return;
	olaf_fp_matcher_destroy(processor->fp_matcher);
	olaf_reader_destroy(processor->reader);
	olaf_fp_extractor_destroy(processor->fp_extractor);
	olaf_ep_extractor_destroy(processor->ep_extractor);
	
	free(processor->audio_data);
	free(processor);
}

void olaf_stream_processor_set_result_callback(Olaf_Stream_Processor * processor,Olaf_FP_Matcher_Result_Callback callback){
	if(processor->fp_matcher) olaf_fp_matcher_set_callback_internal(processor->fp_matcher, callback);
}

void olaf_stream_processor_set_result_header(Olaf_Stream_Processor * processor,const char * result_header){
	if(processor->fp_matcher) olaf_fp_matcher_set_header(processor->fp_matcher, result_header);
}

void olaf_stream_processor_process(Olaf_Stream_Processor * processor){
	
	int audioBlockIndex = 0;

	Olaf_FP_DB_Writer *fp_db_writer = NULL;
	Olaf_FP_Matcher *fp_matcher = processor->fp_matcher;
	Olaf_FP_File_Writer *fp_file_writer = NULL;


	if(processor->runner->mode == OLAF_RUNNER_MODE_STORE || processor->runner->mode == OLAF_RUNNER_MODE_DELETE){
		fp_db_writer = olaf_fp_db_writer_new(processor->runner->db,processor->audio_identifier);
	}else if(processor->runner->mode == OLAF_RUNNER_MODE_PRINT ){
		fp_file_writer = olaf_fp_file_writer_new(stdout);
		olaf_fp_file_writer_write_header(fp_file_writer);
	} else if(processor->runner->mode == OLAF_RUNNER_MODE_CACHE ){
		//create a cache file writer
		fp_file_writer = olaf_fp_file_writer_new(processor->runner->fp_cache_file);
		olaf_fp_file_writer_write_header(fp_file_writer);
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
			} else if(processor->runner->mode == OLAF_RUNNER_MODE_PRINT || processor->runner->mode == OLAF_RUNNER_MODE_CACHE){
				olaf_fp_file_writer_write(fp_file_writer,fingerprints);
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
	//If the main loop never ran (e.g. truncated/empty raw audio file from a
	//racy temp path or just a very short input), eventPoints is still NULL.
	//Skip the final extract in that case to avoid a NULL deref. The empty
	//fingerprints buffer below is fine for the metadata-only paths.
	if(eventPoints != NULL && eventPoints->eventPointIndex > 0){
		fingerprints = olaf_fp_extractor_extract(processor->fp_extractor,eventPoints,audioBlockIndex);
	}
	double audioDuration = (double) olaf_reader_total_samples_read(processor->reader) / (double) processor->config->audioSampleRate;

	if(processor->runner->mode == OLAF_RUNNER_MODE_QUERY){
		//use the fingerprints to match with the reference database
		//report matches if found
		if(fingerprints != NULL){
			olaf_fp_matcher_match(fp_matcher,fingerprints);
		}
		olaf_fp_matcher_print_header(fp_matcher);
		olaf_fp_matcher_print_results(fp_matcher);

	}else if(processor->runner->mode == OLAF_RUNNER_MODE_STORE){
		//use the fp's to store in the db
		if(fingerprints != NULL){
			olaf_fp_db_writer_store(fp_db_writer,fingerprints);
		}
		olaf_fp_db_writer_destroy(fp_db_writer,true);
		Olaf_Resource_Meta_data meta_data;
		meta_data.duration = (float) audioDuration;
		if(processor->orig_path == NULL){
			fprintf(stderr,"Original path is NULL, please add the parameter");
		}else{
			snprintf(meta_data.path,sizeof(meta_data.path),"%s",processor->orig_path);
		}
		meta_data.fingerprints = olaf_fp_extractor_total(processor->fp_extractor);
		olaf_db_store_meta_data(processor->runner->db,&processor->audio_identifier,&meta_data);
	} else if(processor->runner->mode == OLAF_RUNNER_MODE_DELETE){
		if(fingerprints != NULL){
			olaf_fp_db_writer_delete(fp_db_writer,fingerprints);
		}
		olaf_fp_db_writer_destroy(fp_db_writer,false);
		olaf_db_delete_meta_data(processor->runner->db,&processor->audio_identifier);
	} else if(processor->runner->mode == OLAF_RUNNER_MODE_PRINT || processor->runner->mode == OLAF_RUNNER_MODE_CACHE){

		Olaf_Resource_Meta_data meta_data;
		meta_data.duration = (float) audioDuration;
		if(processor->orig_path == NULL){
			fprintf(stderr,"Original path is NULL, please add the parameter");
		}else{
			snprintf(meta_data.path,sizeof(meta_data.path),"%s",processor->orig_path);
		}
		meta_data.fingerprints = olaf_fp_extractor_total(processor->fp_extractor);
		olaf_fp_file_writer_destroy(fp_file_writer,&meta_data,processor->runner->fp_meta_file);
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
	}else if(processor->runner->mode == OLAF_RUNNER_MODE_PRINT){
		verb = "Printed";
	}else if(processor->runner->mode == OLAF_RUNNER_MODE_CACHE){
		verb = "Cached";
	}
	double fingerprintspersecond = olaf_fp_extractor_total(processor->fp_extractor) / audioDuration;
	processor->last_audio_duration = audioDuration;
	processor->last_cpu_time_used = cpu_time_used;
	processor->last_total_fingerprints = olaf_fp_extractor_total(processor->fp_extractor);
	if(!processor->suppress_summary_print){
		fprintf(stderr,"%s %lu fp's from %.1fs (%.0f fp/s) in %.3fs (%.0f times realtime)\n",verb,olaf_fp_extractor_total(processor->fp_extractor), audioDuration,fingerprintspersecond,cpu_time_used,ratio);
	}
}

double olaf_stream_processor_audio_duration(Olaf_Stream_Processor * processor){
	return processor->last_audio_duration;
}

double olaf_stream_processor_cpu_time(Olaf_Stream_Processor * processor){
	return processor->last_cpu_time_used;
}

size_t olaf_stream_processor_total_fingerprints(Olaf_Stream_Processor * processor){
	return processor->last_total_fingerprints;
}

void olaf_stream_processor_set_suppress_summary(Olaf_Stream_Processor * processor, bool suppress){
	processor->suppress_summary_print = suppress;
}
