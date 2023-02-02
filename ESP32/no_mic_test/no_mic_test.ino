
#include "pffft.h"

#include "olaf_config.h"
#include "olaf_window.h"
#include "olaf_db.h"
#include "olaf_ep_extractor.h"
#include "olaf_fp_extractor.h"
#include "olaf_fp_matcher.h"
#include "olaf_audio_ota_852601_2s.h"

size_t audio_block_index;
float * audio_block;
float * all_audio;
size_t all_audio_length;

PFFFT_Setup *fftSetup;
float *fft_in;//fft input
float *fft_out;//fft output
const float* window;

Olaf_Config *config;
Olaf_DB* db;
Olaf_EP_Extractor *ep_extractor;
Olaf_FP_Extractor *fp_extractor;
Olaf_FP_Matcher *fp_matcher;

struct extracted_event_points * eventPoints;
struct extracted_fingerprints * fingerprints;

void setup_olaf(){
  config = olaf_config_esp_32();

  fftSetup = pffft_new_setup(config->audioBlockSize,PFFFT_REAL);
	fft_in = (float*) pffft_aligned_malloc(config->audioBlockSize*4);//fft input
	fft_out= (float*) pffft_aligned_malloc(config->audioBlockSize*4);//fft output

	audio_block = (float *) calloc(sizeof(float),config->audioBlockSize);
	db = olaf_db_new(NULL,true);
  if(db==NULL) Serial.println("db NULL: not enough memory?");
	ep_extractor = olaf_ep_extractor_new(config);
  if(ep_extractor==NULL) Serial.println("ep_extractor NULL: not enough memory?");
	fp_extractor = olaf_fp_extractor_new(config);
  if(fp_extractor==NULL) Serial.println("fp_extractor NULL: not enough memory?");
	fp_matcher = olaf_fp_matcher_new(config,db);
  if(fp_matcher==NULL) Serial.println("fp_matcher NULL: not enough memory?");

  window = olaf_fft_window(config->audioBlockSize); 
}

void setup() {
  Serial.begin(115200);

  Serial.println("[OLAF] Free memory before init: " + String(esp_get_free_heap_size()) + " bytes");
   //print everything to stdout (serial);
  stderr = stdout;
  setup_olaf();
  Serial.println("[OLAF] Free after init: " + String(esp_get_free_heap_size()) + " bytes");

  audio_block_index = 0;
  all_audio = (float *) olaf_audio_ota_852601_2s_raw;
  all_audio_length = olaf_audio_ota_852601_2s_raw_len / 4;

  Serial.printf("[OLAF] Initialized with %zu audio samples. Sample sample: %f\n",all_audio_length,all_audio[all_audio_length/2]);
}

void process_audio_block(){

		//windowing
		for(int i = 0 ; i <  config->audioBlockSize ; i++){
			fft_in[i] = audio_block[i] * window[i];
		}

		//do the transform
		pffft_transform_ordered(fftSetup, fft_in, fft_out, 0, PFFFT_FORWARD);
    
		//extract event points
		eventPoints = olaf_ep_extractor_extract(ep_extractor,fft_out,audio_block_index);

		Serial.printf("Event point index: %d \n",eventPoints->eventPointIndex);
    

		//if there are enough event points
		if(eventPoints->eventPointIndex > config->eventPointThreshold){
      
			//combine the event points into fingerprints
			fingerprints = olaf_fp_extractor_extract(fp_extractor,eventPoints,audio_block_index);

			size_t fingerprintIndex = fingerprints->fingerprintIndex;
			//printf("FP index: %zu \n",fingerprintIndex);

			if(fingerprintIndex > 0){
				
				olaf_fp_matcher_match(fp_matcher,fingerprints);

        olaf_fp_matcher_print_results(fp_matcher);
			}
		}
	
}

void loop(){
  
  size_t step_size = config->audioStepSize;
	size_t block_size = config->audioBlockSize;
	
	size_t overlap_size = block_size - step_size;
	size_t steps_per_block = block_size / step_size;

  size_t start_index = audio_block_index * step_size;
  size_t stop_index = start_index + block_size;

  if(stop_index >= all_audio_length){
    start_index = 0;
    audio_block_index = 0;
  }

  for(size_t i = 0 ; i < block_size ; i++ ){
    audio_block[i] = all_audio[start_index + i];
  }

  process_audio_block();
  printf("[OLAF] processed audio block index: %zu\n",audio_block_index);
  audio_block_index++;
  
  delay(100);
}