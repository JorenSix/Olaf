// Olaf: Overly Lightweight Acoustic Fingerprinting
// Copyright (C) 2019-2025  Joren Six

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.

// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

//
// *****************************************************************
// 
// 
// This is an Arduino patch for an ESP32 with a I2S INMP441 microphone.
// 
// The patch captures samples from an I2S microphone, converts them to
// 32bit le float PCM and tries to match audio to a reference track using
// the Olaf acoustic fingerprinting library.
//
// The reference database fingerprints are encoded in a header file "olaf_fp_ref_mem.h"
// Once the audio matches with the reference a callback method is called which then can respond to
// The recognition event. In this code leds start blinking quickly while a match is found.
// Leds stop blinking once recognition stops. 
// 
// 

#include "pffft.h"
#include "olaf_config.h"
#include "olaf_window.h"
#include "olaf_db.h"
#include "olaf_ep_extractor.h"
#include "olaf_fp_extractor.h"
#include "olaf_fp_matcher.h"

// Include I2S driver
#include <driver/i2s.h>
#include <math.h>

// a gain factor to amplify the sound: samples come out of the
// microphone rather quietly.
uint16_t gain_factor = 40;


// Connections to INMP441 I2S microphone
#define I2S_WS 25
#define I2S_SD 33
#define I2S_SCK 32

#define LED_BUILTIN 11

// Use I2S Processor 0
#define I2S_PORT I2S_NUM_0

// Define input buffer length
#define bufferLen 64
uint8_t sBuffer[bufferLen*2];

size_t audio_block_index;
float * audio_block;
size_t audio_sample_index;

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

void task_blink(void *arg){
    while(1) {
      digitalWrite(LED_BUILTIN, HIGH);  
      delay(80);
      digitalWrite(LED_BUILTIN, LOW);
      delay(80);
    }
}

TaskHandle_t myTask1Handle = NULL; // Task handler


//callback called on match
void olaf_fp_matcher_callback_esp32(int matchCount, float queryStart, float queryStop, const char* path, uint32_t matchIdentifier, float referenceStart, float referenceStop) {
  Serial.printf("%d, %.2f, %.2f, %s, %u, %.2f, %.2f\n", matchCount, queryStart, queryStop, path, matchIdentifier, referenceStart, referenceStop);
  if(matchCount >= 5  && myTask1Handle == NULL){
    xTaskCreate(task_blink, "task_blink", 4096, NULL, 10, &myTask1Handle); 
  }
  if(matchCount == 0 && myTask1Handle != NULL){
    vTaskSuspend(myTask1Handle);
    myTask1Handle = NULL;
  }
  //else
  //digitalWrite(LED_BUILTIN,HIGH)
}

//Setup the olaf structs
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
    fp_matcher = olaf_fp_matcher_new(config,db,olaf_fp_matcher_callback_esp32);
  if(fp_matcher==NULL) Serial.println("fp_matcher NULL: not enough memory?");

  window = olaf_fft_window(config->audioBlockSize);

  size_t step_size = config->audioStepSize;
  size_t block_size = config->audioBlockSize;
  size_t overlap_size = block_size - step_size;
  //initialize the first sample to be read at overlap_size =
  audio_sample_index = overlap_size;
}

void i2s_install() {
  // Set up I2S Processor configuration
  const i2s_config_t i2s_config = {
    .mode = i2s_mode_t(I2S_MODE_MASTER | I2S_MODE_RX),
    .sample_rate = 16000,
    .bits_per_sample = i2s_bits_per_sample_t(16),
    .channel_format = I2S_CHANNEL_FMT_ONLY_LEFT,
    .communication_format = i2s_comm_format_t(I2S_COMM_FORMAT_STAND_I2S),
    .intr_alloc_flags = 0,
    .dma_buf_count = 8,
    .dma_buf_len = bufferLen,
    .use_apll = false
  };

  i2s_driver_install(I2S_PORT, &i2s_config, 0, NULL);
}

void i2s_setpin() {
  // Set I2S pin configuration
  const i2s_pin_config_t pin_config = {
    .bck_io_num = I2S_SCK,
    .ws_io_num = I2S_WS,
    .data_out_num = -1,
    .data_in_num = I2S_SD
  };

  i2s_set_pin(I2S_PORT, &pin_config);
}

void setup() {
  Serial.begin(115200);

  pinMode(LED_BUILTIN, OUTPUT);

  i2s_install();
  i2s_setpin();
  i2s_start(I2S_PORT);

  Serial.println("[OLAF] Free memory before init: " + String(esp_get_free_heap_size()) + " bytes");
   //print everything to stdout (serial);
  stderr = stdout;
  setup_olaf();
  Serial.println("[OLAF] Free after init: " + String(esp_get_free_heap_size()) + " bytes");

  for(size_t i = 0 ; i < 10 ; i++){
    digitalWrite(LED_BUILTIN, HIGH);  // turn the LED on (HIGH is the voltage level)
    delay(100);                      // wait for a second
    digitalWrite(LED_BUILTIN, LOW);   // turn the LED off by making the voltage LOW
    delay(120);   
  }
}

void process_audio_block(){
  //windowing and store in FFT input
  for(int i = 0 ; i <  config->audioBlockSize ; i++){
    fft_in[i] = audio_block[i] * window[i];
  }

  //do the transform
  pffft_transform_ordered(fftSetup, fft_in, fft_out, 0, PFFFT_FORWARD);
  
  //extract event points
  eventPoints = olaf_ep_extractor_extract(ep_extractor,fft_out,audio_block_index);

  //Serial.printf("Event point index: %d \n",eventPoints->eventPointIndex);
  

  //if there are enough event points
  if(eventPoints->eventPointIndex > config->eventPointThreshold){
    
    //combine the event points into fingerprints
    fingerprints = olaf_fp_extractor_extract(fp_extractor,eventPoints,audio_block_index);

    size_t fingerprintIndex = fingerprints->fingerprintIndex;
    //printf("FP index: %zu \n",fingerprintIndex);

    if(fingerprintIndex > 0){
      olaf_fp_matcher_match(fp_matcher,fingerprints);
    }

    //handled all fingerprints set index back to zero
    fingerprints->fingerprintIndex = 0;
  }
}


void loop(){
  
  size_t step_size = config->audioStepSize;
  size_t block_size = config->audioBlockSize;
  size_t overlap_size = block_size - step_size;


  // Get I2S data and place in data buffer
  size_t bytesIn = 0;
  esp_err_t result = i2s_read(I2S_PORT, &sBuffer, bufferLen, &bytesIn, portMAX_DELAY);
  
  if (result == ESP_OK && bytesIn > 0){

    int16_t * sample_buffer = (int16_t *) sBuffer;

    // Read I2S data buffer
    // I2S reads stereo data and one channel is zero the other contains
    // data, both have 2 bytes per sample
    int16_t samples_read = bytesIn / 2;
    
    
    for(size_t i = 0 ; i < samples_read ; i++){
      sample_buffer[i] = gain_factor * sample_buffer[i];
      //Max for signed int16_t is 2^15
      audio_block[audio_sample_index] = sample_buffer[i] / 32768.f;
      audio_sample_index++;

      if(audio_sample_index==block_size){
        process_audio_block();
        //printf("[OLAF] processed audio block index: %zu\n",audio_block_index);
        audio_block_index++;

        //shift samples to make room for new samples
        for(size_t j = 0; j < overlap_size ; j++){
          audio_block[j] = audio_block[j+step_size];
        }
        audio_sample_index=overlap_size;
      }
    }

  }
}




