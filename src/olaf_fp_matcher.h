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
#ifndef OLAF_FP_MATCHER_H
#define OLAF_FP_MATCHER_H

	#include "olaf_fp_extractor.h"
	#include "olaf_fp_db.h"
	#include "olaf_config.h"
	
	typedef struct Olaf_FP_Matcher Olaf_FP_Matcher;

	Olaf_FP_Matcher * olaf_fp_matcher_new(Olaf_Config * config,Olaf_FP_DB* db );
	
	int olaf_fp_matcher_match(Olaf_FP_Matcher *, struct extracted_fingerprints *);

	void olaf_fp_matcher_destroy(Olaf_FP_Matcher * );

#endif // OLAF_FP_MATCHER_H
