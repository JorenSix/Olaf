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
#include <stdbool.h> //bool 
#include <string.h> //bool 
#include <stdlib.h> //bool 

#ifndef OLAF_CONFIG_H
#define OLAF_CONFIG_H

	typedef struct Olaf_Config Olaf_Config;

	struct Olaf_Config{

		char* dbFolder;

		//------ General Configuration

		//The size of a single audio block, 
		//  512 samples
		int audioBlockSize;
		
		//The sample rate of the incoming audio
		// 	8000Hz
		int audioSampleRate;

		//The size of a step from one block of samples
		// 256 samples (with an audio block size of 512 = 50% overlap)
		int audioStepSize;

		//The size of a single audio sample
		//	32 bit float samples => 4 bytes
		int bytesPerAudioSample;

		//Print verbose info or not
		// false
		bool printDebugInfo;


		//------ EVENT POINT Configuration

		//Max number of event points per audio block
		//
		int maxEventPointsPerBlock;

		//The filter size of the max filter in time (horizontal direction)
		int filterSizeTime;
		int halfFilterSizeTime;
		int filterSizeFrequency;
		int halfFilterSizeFrequency;

		//To avoid extracting event points of silence,
		//the ep magnitude should be at least this value
		float minEventPointMagnitude;


		//Max number of event points before they are 
		//combined into fingerprints 
		//(parameter should not have any effect,except for memory use)
		int maxEventPoints;
		// Once this number of event points is listed, start combining
		//them into fingerprints: should be less than maxEventPoints
		int eventPointThreshold;

		
		//-----------Fingerprint configuration

		//the minimum and maximum time distance of event points in 
		//
		int minTimeDistance;
		int maxTimeDistance;
		// The minimum and maximum frequency bin distance in fft bins
		int minFreqDistance;
		int maxFreqDistance;

		//Reuse each event point maximally this number of times
		int maxFingerprintsPerPoint;

		// 
		int maxFingerprints;

		// number of recent fingerprints to compare a 
		// new fingerprint with to see if it is actually new or
		// already discovered
		int recentFingerprintSize;

		//------------ Matcher configuration

		int maxResults;

		//minimum 5 aligned matches before reporting match
		int minMatchCount;

		//To prevent that noise matches 
		int minMatchTimeDiff;

		int maxResultAge;//7.5 seconds

		//maximum number of results returned from the database
		//It can be considered as the number of times a fingerprint hash
		//is allowed to collide
		int maxDBCollisions;

		//if true then each fingerprint query is repeated three times:
		//  once with the original time bin, 
		//  once with the original time bin + 1,
		//  once with the original time bin - 1
		// This to include off by one matches, which might increase matches.
		//   the disadvantage is that
		//   query performance decreases (from 1 query -> 3 queries per print)
		bool includeOffByOneMatches;

	};

	Olaf_Config* olaf_config_default();

	void olaf_config_destroy(Olaf_Config *);

#endif // OLAF_CONFIG_H

