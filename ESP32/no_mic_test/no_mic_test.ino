
#include "olaf_config.h"

void setup() {
  Serial.begin(115200);

  Olaf_Config* config = olaf_config_default();
  Serial.println(config->audioBlockSize);    
}

void loop(){
  
}