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

#include "olaf_config.h"

Olaf_Config* olaf_config_default(){
	Olaf_Config *config = (Olaf_Config*) malloc(sizeof(Olaf_Config));

	//construct the directory to write db info to: /home/user/.olaf/db/
	const char * homeDir = getenv("HOME");

	//This assume a UNIX file separator
	const char* dbDir = "/.olaf/db/";
	char * fullDbFolderName = (char *) malloc(strlen(homeDir) +  strlen(dbDir));
	strcpy(fullDbFolderName,homeDir);
	strcat(fullDbFolderName,dbDir);

	config->dbFolder = fullDbFolderName;

	//audio info
	config->audioBlockSize = 512;
	config->audioSampleRate = 8000;
	config->audioStepSize= config->audioBlockSize / 2;

	config->bytesPerAudioSample = 4; //32 bits float

	//write debug files to visualize in sonic visualizer
	config->printDebugInfo = false;

	//Number of event points per 256 audio samples (32ms)
	config->maxEventPointsPerBlock=3;
	config->maxEventPoints=60;
	config->eventPointThreshold = 20;
	config->minMagnitude = 0.05;//an event point needs to have at least this magnitude
	config->minContrast=3.0;//an event point needs to have at least this contrast with its surroundings (x times the average in surroundings)

	//the filter used in both frequency as time direction 
	//to find maxima
	config->filterSize=15; // 11 * 32 = 350 ms
	config->halfFilterSize=config->filterSize/2;

	//min time distance between two event points for fingerprint
	config->minTimeDistance = 2; // 32ms x 2 (+-64ms) for fingerprint construction
	//max time distance between two event points for fingerprint
	config->maxTimeDistance = config->minTimeDistance + 46; // 32ms * (2 + 16) = 576ms for fingerprint construction
	//min freq distance between two event points for fingerprint
	config->minFreqDistance = 3; //bins for fingerprint construction
	//max freq distance between two event points for fingerprint
	config->maxFreqDistance = config->minFreqDistance + (1<<6); //bins for fingerprint construction
	//number of times a event point is reused
	config->maxFingerprintsPerPoint = 3;

	//to check if fingerprint is actually new
	config->recentFingerprintSize=30;

	config->maxFingerprints=300;

	//maximum number of results
	config->maxResults = 10;

	//minimum 5 aligned matches before reporting match
	config->minMatchCount = 5;

	//Forget matches after x audio blocks
	config->maxResultAge = 350;//7.5 seconds
	
	//number of matches (hash collisions) 
	config->maxDBCollisions = 1000;//for larger data sets use around 2000

	//Find matches for t1 + 1, t1 + 0 and t1 -0 or not
	// triples the number of queries to the database to
	// offset off by one errors (time discretisation error)
	config->includeOffByOneMatches = false;

	return config;
}

void olaf_config_destroy(Olaf_Config * config){
	free(config->dbFolder);
	free(config);
}
