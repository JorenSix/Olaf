// Olaf: Overly Lightweight Acoustic Fingerprinting
// Copyright (C) 2019-2023  Joren Six

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
// 32bit le float PCM and sends them over an UDP socket to a receiver
// with a chosen IP address.
// 
// On the receiver, to listen to the microphone:
// use netcat in combination with ffplay, part of the ffmpeg suite
// 
// nc -l -u 3000 | ffplay -f f32le -ar 16000 -ac 1  -
//
// To capture the audio, use netcat and ffmpeg to store the audio
// in a wav-file
// 
// nc -l -u 3000 | ffmpeg -f f32le -ar 16000 -ac 1 -i pipe: microphone.wav

#include <WiFi.h>
#include <WiFiUdp.h>

// Include I2S driver
#include <driver/i2s.h>
#include <math.h>

//addres of the sound receiving computer and the UDP port
//that is used
IPAddress outIp(192, 168, 88, 253);
int outPort = 3000;

// a gain factor to amplify the sound: samples come out of the
// microphone rather quietly.
uint16_t gain_factor = 40;

// Connections to INMP441 I2S microphone
#define I2S_WS 25
#define I2S_SD 33
#define I2S_SCK 32

// Use I2S Processor 0
#define I2S_PORT I2S_NUM_0

// Define input buffer length
#define bufferLen 64
uint8_t sBuffer[bufferLen*2];

WiFiUDP Udp;

const char * ssid = "****";
const char * password = "*****";

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

void connect_wifi(){

  WiFi.mode(WIFI_STA);
  WiFi.begin(ssid, password);
  if (WiFi.waitForConnectResult() != WL_CONNECTED) {
      Serial.println("WiFi Failed");
      while(1) {
          delay(500);
      }
  }
  // you are now connected:
  Serial.print("You are connected to the network ");
  Serial.println(ssid);
}

void setup() {
  Serial.begin(115200);

  Serial.println(" ");
  Serial.println("Starting WiFi microphone");

  connect_wifi();

  // Set up I2S
  i2s_install();
  i2s_setpin();
  i2s_start(I2S_PORT);
}

void loop() {

  // Get I2S data and place in data buffer
  size_t bytesIn = 0;
  esp_err_t result = i2s_read(I2S_PORT, &sBuffer, bufferLen, &bytesIn, portMAX_DELAY);
  
  if (result == ESP_OK && bytesIn > 0){


    int16_t * sample_buffer = (int16_t *) sBuffer;

    // Read I2S data buffer
    // I2S reads stereo data and one channel is zero the other contains
    // data, both have 2 bytes per sample
    int16_t samples_read = bytesIn / 2;
    float audio_block_float[samples_read];
    
    for(size_t i = 0 ; i < samples_read ; i++){
      sample_buffer[i] = gain_factor * sample_buffer[i];
      //Max for signed int16_t is 2^15
      audio_block_float[i] = sample_buffer[i] / 32768.f;
    }

    // Send raw audio 32bit float samples over UDP
    Udp.beginPacket(outIp, outPort);
    Udp.write((const uint8_t*) audio_block_float,bytesIn*2);
    Udp.endPacket();
  }
}