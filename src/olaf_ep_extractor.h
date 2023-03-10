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

/**
 * @file olaf_ep_extractor.h
 *
 * @brief Olaf event point extractor.
 *
 * This defines the interface on how event points (EPs or eps) are extracted
 * from audio blocks.
 */

#ifndef OLAF_EP_EXTRACTOR_H
#define OLAF_EP_EXTRACTOR_H

	#include "olaf_config.h"
	
	/**
	 * @struct eventpoint
	 * @brief An event point is a combination of a frequency bin, time bin and magnitude
	 */  
	struct eventpoint {
		int frequencyBin;
		int timeIndex;
		float magnitude;
		int usages;
	};

	
	/**
	 * @struct extracted_event_points
	 * @brief The result of event point extraction is a list of event points.
	 */
	struct extracted_event_points{
		struct eventpoint * eventPoints;
		int eventPointIndex;
	};
	
	/**
	 * @struct Olaf_EP_Extractor
	 *
	 * @brief Contains state information for event point (EP) extraction.
	 * 
	 * The memory used by the ep extractor should be freed in the  @_destroy@ method. 
	 */
	typedef struct Olaf_EP_Extractor Olaf_EP_Extractor;

	/**
	 * Initialize a new @ref Olaf_EP_Extractor struct according to the given configuration.
	 * @param config The configuration currenlty in use.
	 * @return An initialized @ref Olaf_EP_Extractor struct or undefined if memory could not be allocated.
	 */
	Olaf_EP_Extractor * olaf_ep_extractor_new(Olaf_Config * config);

	/**
	 * A helper (debug) method to print a single event point.
	 * @param eventpoint The event point to print.
	 */
	void olaf_ep_extractor_print_ep(struct eventpoint);

	/**
	 * The actual extract method which extracts event points from the current fft magnitudes.
	 * @param olaf_ep_extractor The EP extractor to destroy.
	 * @param fft_magnitudes The fft magnitudes for the current audio block.
	 * @param audioBlockIndex The audio block time index.
	 */
	struct extracted_event_points * olaf_ep_extractor_extract(Olaf_EP_Extractor * olaf_ep_extractor, float* fft_magnitudes, int audioBlockIndex);

	/**
	 * Free memory or other resources.
	 * @param  olaf_ep_extractor The EP extractor to destroy.
	 */ 
	void olaf_ep_extractor_destroy(Olaf_EP_Extractor * olaf_ep_extractor );


#endif // OLAF_EP_EXTRACTOR_H
