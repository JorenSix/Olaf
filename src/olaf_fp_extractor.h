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
#ifndef OLAF_FP_EXTRACTOR_H
#define OLAF_FP_EXTRACTOR_H

	#include "olaf_config.h"
	#include "olaf_ep_extractor.h"
	#include <stdint.h>
	
	// A fingerprint consists of two event points
	// So it has two frequency bins and two time indexes
	struct fingerprint{
		int frequencyBin1;
		float fractionalFrequencyBin1;
		int timeIndex1;

		int frequencyBin2;
		float fractionalFrequencyBin2;
		int timeIndex2;
		
		int frequencyBin3;
		float fractionalFrequencyBin3;
		int timeIndex3;
	};

	//This struct is shared to report the fingerprints
	struct extracted_fingerprints{
		struct fingerprint * fingerprints;
		size_t fingerprintIndex;
	};
	
	typedef struct Olaf_FP_Extractor Olaf_FP_Extractor;

	Olaf_FP_Extractor * olaf_fp_extractor_new(Olaf_Config * config);

	// free up memory and release resources
	void olaf_fp_extractor_destroy(Olaf_FP_Extractor * );

	// extract fingerprints from a list of event points
	struct extracted_fingerprints * olaf_fp_extractor_extract(Olaf_FP_Extractor *,struct extracted_event_points * ,int);

	//static methods:

	//hash a fingerprint
	uint32_t olaf_fp_extractor_hash(struct fingerprint f);

	//to sort hashes use this comparator
	int olaf_fp_extractor_compare_fp(const void * a, const void * b);

	//run a test to check encoding and decoding hashes and bit manipulations
	void olaf_fp_extractor_fp_hash_test();

#endif // OLAF_FP_EXTRACTOR_H
