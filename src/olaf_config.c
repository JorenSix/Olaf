// Olaf: Overly Lightweight Acoustic Fingerprinting
// Copyright (C) 2019-2020  Joren Six

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
#include <stdbool.h>
#include <stdlib.h>
#include <stdio.h>

#include "olaf_config.h"

Olaf_Config* olaf_config_default(){
	Olaf_Config *config = (Olaf_Config *) malloc(sizeof(Olaf_Config));

	//construct the directory to write db info to: /home/user/.olaf/db/
	const char * homeDir = getenv("HOME");
	if (homeDir == NULL){
		fprintf(stderr,"No home directory found, will use './db' as db folder");
		config->dbFolder = "db";
	}else{
		//This assume a UNIX file separator
		const char* dbDir = "/.olaf/db/";
		size_t length = strlen(homeDir) +  strlen(dbDir) + 1;
		char * fullDbFolderName = (char *) malloc(length);
		strcpy(fullDbFolderName,homeDir);
		strcat(fullDbFolderName,dbDir);
		fullDbFolderName[length-1] = '\0';
		config->dbFolder = fullDbFolderName;
	}	

	//audio info
	config->audioBlockSize = 1024;
	config->audioSampleRate = 16000;
	config->audioStepSize = 128;

	config->bytesPerAudioSample = 4; //32 bits float

	config->maxEventPoints=60;
	config->eventPointThreshold = 30;

	//the filter used in both frequency as time direction 
	//to find maxima
	config->filterSizeFrequency=103;//frequency bins 
	config->halfFilterSizeFrequency=config->filterSizeFrequency/2;

	config->filterSizeTime=25;// 25 * 128/16 = 200 ms
	config->halfFilterSizeTime=config->filterSizeTime/2;

	//prevent silence to register as event points
	config->minEventPointMagnitude = 0.001;

	//debug statements
	config->verbose = false;
	
	//For over the air queries it is best to ignore magnitude info
	config->useMagnitudeInfo=false;
	//min time distance between two event points for fingerprint
	config->minTimeDistance = 2; // 8ms x 2 for fingerprint construction
	//max time distance between two event points for fingerprint
	config->maxTimeDistance = 33; // 8ms * 33 = 264ms for fingerprint construction
	//min freq distance between two event points for fingerprint
	config->minFreqDistance = 1; //bins for fingerprint construction
	//max freq distance between two event points for fingerprint
	config->maxFreqDistance = 128; //bins for fingerprint construction
	
	config->maxFingerprints=300;

	//maximum number of results
	config->maxResults = 50;

	//The range around a hash to search
	config->searchRange = 5;

	//minimum aligned matches before reporting match
	config->minMatchCount = 6;

	//Forget matches after x seconds
	//or never when zero
	config->keepMatchesFor = 0;//seconds
	//print results after x seconds or only at the end of stream (when zero)
	config->printResultEvery = 0;//seconds
	
	//number of matches (hash collisions) 
	config->maxDBCollisions = 2000;//for larger data sets use around 2000

	return config;
}

Olaf_Config* olaf_config_test(){
	Olaf_Config* config =  olaf_config_default();

	const char* dbDir = "tests/olaf_test_db";
	char * folderName = (char *) malloc(strlen(dbDir)+1);
	strcpy(folderName,dbDir);

	config->dbFolder = folderName;

	return config;
}

Olaf_Config* olaf_config_esp_32(){
	Olaf_Config* config =  olaf_config_default();

	//debug statements
	config->verbose = true;

	config->minMatchCount = 2;

	config->maxEventPoints = 30;
	config->eventPointThreshold = 15;

	config->maxFingerprints = 200;
	config->maxDBCollisions = 100;//for larger data sets use around 2000

	config->filterSizeFrequency=77;//frequency bins 
	config->halfFilterSizeFrequency=config->filterSizeFrequency/2;

	config->filterSizeTime=15;
	config->halfFilterSizeTime=config->filterSizeTime/2;

	config->keepMatchesFor = 0;//seconds
	//print results after x seconds or only at the end of stream (when zero)
	config->printResultEvery = 0;//seconds

	return config;
}

Olaf_Config* olaf_config_mem(){
	Olaf_Config* config =  olaf_config_esp_32();
	config->verbose = false;
	return config;
}

void olaf_config_destroy(Olaf_Config * config){
	free(config->dbFolder);
	free(config);
}
