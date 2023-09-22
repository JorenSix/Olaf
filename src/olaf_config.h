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
#include <stdbool.h> //bool 
#include <string.h> //bool 
#include <stdlib.h> //bool 
#include <stdio.h>

/**
 * @file olaf_config.h
 *
 * @brief Olaf configuration pramameters.
 *
 * Holds the compile time configuration parameters.
 *
 * To create a new queue, use @ref olaf_config_default.  To destroy a queue, use
 * @ref olaf_config_destroy.
 *
 */


#ifndef OLAF_CONFIG_H
#define OLAF_CONFIG_H
	
	typedef struct Olaf_Config Olaf_Config;

	/**
	 * @struct Olaf_Config
	 * @brief Configuration parameters defining the behaviour of Olaf.
	 * 
	 * Olaf_Config configuration parameters define the behaviour of Olaf.
	 * The configuration determines how Olaf behaves. The configuration settings are
	 * set at compile time and should not change in between runs: if they do it is
	 * possible that e.g. indexed fingerprints do not match extracted prints any more.
	 */
	struct Olaf_Config{

		char * dbFolder;

		//------ General Configuration

		/** The size of a single audio block: e.g. 1024 samples*/
		int audioBlockSize;
		
		/**The sample rate of the incoming audio: e.g. 16000Hz.*/
		int audioSampleRate;

		/**The size of a step from one block of samples to the next: e.g. 128 samples.*/
		int audioStepSize;

		/**The size of a single audio sample. For example a 32 bit float sample consists of 4 bytes */
		int bytesPerAudioSample;

		/** Print debug info. If true a lot of messages are printed to the console. */ 
		bool verbose;

		//------ EVENT POINT Configuration

		/** Max number of event points per audio block */
		int maxEventPointsPerBlock;

		/**The filter size of the max filter in time (horizontal direction), expressed in blocks*/
		int filterSizeTime;

		/** Half of the filter size in time */
		int halfFilterSizeTime;
		
		/**The filter size of the max filter in frequency (vertical direction), either expressed in fft bins or in MIDI notes (12 midi notes is an octave).*/
		int filterSizeFrequency;
		int halfFilterSizeFrequency;

		/**To avoid extracting event points of silence, the ep magnitude should be at least this value*/
		float minEventPointMagnitude;

		/**Frequency bins below this value are not used in ep extraction.*/
		int minFrequencyBin;

		/**the amount each event point is reused*/
		int maxEventPointUsages;


		/**Max number of event points before they are 
		 *combined into fingerprints 
		 *(parameter should not have any effect,except for memory use)
		 */
		int maxEventPoints;
		/** Once this number of event points is listed, start combining 
		 * them into fingerprints: should be less than maxEventPoints 
		 */
		int eventPointThreshold;

		/**Calculating the square root of the magnitude is not
		 * strictly needed for event point extraction, but for debug and
		 * visualization it can be practical, default is false. 
		 */
		bool sqrtMagnitude;
		//-----------Fingerprint configuration
		
		/** Include magnitude info in fingerprints or not.
		 * For over the air queries it is best to 
		 * not include magnitude info in fingerprint
		 */
		bool useMagnitudeInfo;

		/**Number of event points per fingerprint. Should be either three (for clean queries) or two for noisy queries.*/
		int numberOfEPsPerFP;

		/** The minimum time distance of event points in time steps. */
		int minTimeDistance;
		/** The maximum time distance of event points in time steps. */
		int maxTimeDistance;

		/** The minimum frequency bin distance in fft bins. */
		int minFreqDistance;
		/** The maximum frequency bin distance in fft bins. */
		int maxFreqDistance;

		/** The maximum number of fingerprints to keep in memory during fingerprint extraction. */
		size_t maxFingerprints;


		//------------ Matcher configuration

		/** The maximum number of result in the matching step. */
		size_t maxResults;

		/** The search range which allows small deviations from the fingerprint hashes. */
		int searchRange;

		/** The minimum number of aligned matches before reporting match */
		int minMatchCount;

		/** The minimum duration of a match before it is reported: 5 matches over 2 seconds indicates a more reliable 
		 * match than 5 matches in 0.1s. It is expressed in seconds. 
		 * Zero means that all matches are reported.
		 */
		float minMatchTimeDiff;

		/** After this time, in seconds, a match is forgotten. This especially relevant for streams. Set to 0 to keep all matches. */
		float keepMatchesFor;

		/** Print result every x seconds */
		float printResultEvery;

		/** maximum number of results returned from the database
		 * It can be considered as the number of times a fingerprint hash
		 * is allowed to collide */
		size_t maxDBCollisions;
	};

	/**
	 * The default configuration to use on traditional computers.
	 *  @return   A new configuration struct, or NULL if it was not possible to allocate the memory.
	 */
	Olaf_Config* olaf_config_default(void);


	/**
	 * The configuration to use for (unit) tests.
	 * @return   A new configuration struct, or NULL if it was not possible to allocate the memory.
	 */
	Olaf_Config* olaf_config_test(void);

	/**
	 * The configuration to use on ESP32 microcontrollers.
	 * @return   A new configuration struct, or NULL if it was not possible to allocate the memory.
	 */
	Olaf_Config* olaf_config_esp_32(void);

	/**
	 * The configuration to use for an in memory database. This is mainly to test the ESP32 code.
	 * @return   A new configuration struct, or NULL if it was not possible to allocate the memory.
	 */
	Olaf_Config* olaf_config_mem(void);

	/**
	 * Free the memory used by the configuration struct
	 * @param config      The configuration struct to destroy.
	 */
	void olaf_config_destroy(Olaf_Config *config);

#endif // OLAF_CONFIG_H

