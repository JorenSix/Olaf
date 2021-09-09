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
	Olaf_Config *config = malloc(sizeof(Olaf_Config));

	//construct the directory to write db info to: /home/user/.olaf/db/
	const char * homeDir = getenv("HOME");

	//This assume a UNIX file separator
	const char* dbDir = "/.olaf/db/";
	char * fullDbFolderName = malloc(strlen(homeDir) +  strlen(dbDir));
	strcpy(fullDbFolderName,homeDir);
	strcat(fullDbFolderName,dbDir);

	config->dbFolder = fullDbFolderName;

	//audio info
	config->audioBlockSize = 1024;
	config->audioSampleRate = 16000;
	config->audioStepSize= 128;

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
	config->minEventPointMagnitude = 0.0;

	config->verbose = false;
	
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
	config->maxResults = 10;

	//The range around a hash to search
	config->searchRange = 5;

	//minimum 5 aligned matches before reporting match
	config->minMatchCount = 6;

	//Forget matches after x audio blocks
	config->maxResultAge = 350;//7.5 seconds
	
	//number of matches (hash collisions) 
	config->maxDBCollisions = 1000;//for larger data sets use around 2000

	//Find matches for t1 + 1, t1 + 0 and t1 -0 or not
	// triples the number of queries to the database to
	// offset off by one errors (time discretisation error)
	config->includeOffByOneMatches = true;

	return config;
}

Olaf_Config* olaf_config_test(){
	Olaf_Config* config =  olaf_config_default();
	free(config->dbFolder);

	const char* dbDir = "tests/olaf_test_db";
	char * folderName = (char *) malloc(strlen(dbDir)+1);
	strcpy(folderName,dbDir);

	config->dbFolder = folderName;

	return config;
}

void olaf_config_destroy(Olaf_Config * config){
	free(config->dbFolder);
	free(config);
}
