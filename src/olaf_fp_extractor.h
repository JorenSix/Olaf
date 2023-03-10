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

/**
 * @file olaf_fp_extractor.h
 *
 * @brief Olaf fingerprint extractor: combines event points into fingerprints.
 *
 * The fingerprint extractor is responsible for combining event points into
 * fingerprints and also defines the fingerprint struct.
 */
#ifndef OLAF_FP_EXTRACTOR_H
#define OLAF_FP_EXTRACTOR_H

	#include "olaf_config.h"
	#include "olaf_ep_extractor.h"
	#include <stdint.h>
	
	// A fingerprint consists of two event points
	// So it has two frequency bins and two time indexes
    /**
	 * @struct fingerprint
	 * 
	 * @brief A fingerprint is a combination of three event points each 
	 * with a frequency bin, time bin and magnitude. 
	 * 
	 * Potentially the thrid event point information can be set to zero. 
	 * This is basically means falling back to using only 2 event points.
	 */
	struct fingerprint{
		int frequencyBin1;
		int timeIndex1;
		float magnitude1;

		int frequencyBin2;
		int timeIndex2;
		float magnitude2;

		int frequencyBin3;
		int timeIndex3;
		float magnitude3;
	};

	/**
	 * @struct extracted_fingerprints
	 * 
	 * @brief The result of fingerprint extraction: a list of fingerprints
	 * with a size. 
	 * 
	 */
	struct extracted_fingerprints{
		struct fingerprint * fingerprints;
		size_t fingerprintIndex;
	};
	
	/**
	 * @struct Olaf_FP_Extractor
	 * 
	 * @brief State information for the fingerprint extractor. 
	 * 
	 */
	typedef struct Olaf_FP_Extractor Olaf_FP_Extractor;

	/**
	 * Create a new fingerprint extractor based on the current config.
	 * @param config The current configuration.
	 */ 
	Olaf_FP_Extractor * olaf_fp_extractor_new(Olaf_Config * config);

	/**
	 * Free up memory and release resources.
	 * @param olaf_fp_extractor The state to clean up.
	 */ 
	void olaf_fp_extractor_destroy(Olaf_FP_Extractor * olaf_fp_extractor);

	/**
	 * Extract fingerprints from a list of event points.
	 * @param olaf_fp_extractor  The state information.
	 * @param eps A pointer to a list of event points.
	 * @param audioBlockIndex The current audio block index.
	 */ 
	struct extracted_fingerprints * olaf_fp_extractor_extract(Olaf_FP_Extractor * olaf_fp_extractor,struct extracted_event_points * eps,int audioBlockIndex);
	
	/**
	 * @brief      Returns the total number of extracted fingerprints.
	 *
	 * @param      fp_extractor  The fp extractor
	 *
	 * @return     The total number of extracted fingerprints.
	 */
	size_t olaf_fp_extractor_total(Olaf_FP_Extractor * fp_extractor);

	//static methods:

	/**
	 * @brief      Calculate a hash for a fingerprint
	 *
	 * @param[in]  f     The fingerprint to calculate a hash for.
	 *
	 * @return     A uint64_t hash for a fingerprint.
	 */
	uint64_t olaf_fp_extractor_hash(struct fingerprint f);

	/**
	 * @brief      Print a single fingerprint, mainly for debug purposes.
	 *
	 * @param[in]  f     The single fingerprint to print.
	 */
	void olaf_fp_extractor_print(struct fingerprint f);

	//to sort hashes use this comparator
	
	/**
	 * @brief      A comparator to sort fingerprint hashes.
	 *
	 * @param[in]  a     The first fingerprint hash.
	 * @param[in]  b     The second fingerprint hash.
	 *
	 * @return     An integer describing the hash order.
	 */
	int olaf_fp_extractor_compare_fp(const void * a, const void * b);

#endif // OLAF_FP_EXTRACTOR_H
