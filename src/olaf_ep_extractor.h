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
#ifndef OLAF_EP_EXTRACTOR_H
#define OLAF_EP_EXTRACTOR_H

	#include "olaf_config.h"
	
	//an event point is a combination of a frequency bin and time bin
	//the magnitude 
	struct eventpoint {
		int frequencyBin;
		int timeIndex;
		float magnitude;
		int usages;
	};

	//this is shared with the interface to the outside
	struct extracted_event_points{
		struct eventpoint * eventPoints;
		int eventPointIndex;
	};
	
	typedef struct Olaf_EP_Extractor Olaf_EP_Extractor;

	Olaf_EP_Extractor * olaf_ep_extractor_new(Olaf_Config * config);

	void olaf_ep_extractor_print_ep(struct eventpoint);

	struct extracted_event_points * olaf_ep_extractor_extract(Olaf_EP_Extractor *, float* fft_magnitudes, int audioBlockIndex);

	//free memory resources and 
	void olaf_ep_extractor_destroy(Olaf_EP_Extractor * );


#endif // OLAF_EP_EXTRACTOR_H
