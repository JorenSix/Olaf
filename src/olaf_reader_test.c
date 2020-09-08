#include <stdio.h>
#include <stdlib.h>

#include "olaf_config.h"
#include "olaf_reader.h"

int main(int argc, const char* argv[]){
	const char* audio_file_name = argv[1];
	Olaf_Config *config = olaf_config_default();

	Olaf_Reader *reader = olaf_reader_new(config,audio_file_name);

	float audio_data[512];

	size_t samples_expected = config->audioStepSize;

	size_t tot_samples_read = 0;

	//read the first block
	size_t samples_read = olaf_reader_read(reader,audio_data);
	tot_samples_read += samples_read;

	while(samples_read==samples_expected){
		samples_read = olaf_reader_read(reader,audio_data);
		tot_samples_read += samples_read;
	}

	printf("%zu\n",tot_samples_read);

	olaf_reader_destroy(reader);
	olaf_config_destroy(config);
}
