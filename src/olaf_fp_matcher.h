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
 * @file olaf_fp_matcher.h
 * @brief Provides an algorithm to match extracted fingerprints with the 
 * indexed fingerprints in the database.
 */

#ifndef OLAF_FP_MATCHER_H
#define OLAF_FP_MATCHER_H

	#include "olaf_fp_extractor.h"
	#include "olaf_db.h"
	#include "olaf_config.h"
	
	/**
	 * @struct Olaf_FP_Matcher
	 * @brief A matcher matches extracted fingerprints with a database. 
	 * A struct to keep the internal state of the matcher hidden and should 
	 * not be used in other places
	 */
	typedef struct Olaf_FP_Matcher Olaf_FP_Matcher;

	//Create a new matcher which matches incoming fingerprints with a database. 

	/**
	 * @brief      Initialize a new matcher
	 *
	 * @param      config  The current configuration
	 * @param      db      The database
	 *
	 * @return     A newly initialzed state struct, or undefined if memory could not be allocated.
	 */
	Olaf_FP_Matcher * olaf_fp_matcher_new(Olaf_Config * config,Olaf_DB* db );
	
	//Matches fingerprints to the database and updates internal state
	
	/**
	 * @brief      Match fingerprints with the database.
	 *
	 * @param      olaf_fp_matcher  The olaf fp matcher
	 * @param      olaf_fps         The fingerprints
	 */
 	void olaf_fp_matcher_match(Olaf_FP_Matcher * olaf_fp_matcher, struct extracted_fingerprints * olaf_fps);

	//Remove old matches

	void olaf_fp_matcher_mark_old_matches(Olaf_FP_Matcher * olaf_fp_matcher, int current_query_time);

	//Print the header to interpret the csv results
	
	/**
	 * @brief      Print a header for the CSV output.
	 */
	void olaf_fp_matcher_print_header(void);

	/**
	 * @brief      Print the current results.
	 *
	 * @param      olaf_fp_matcher  The olaf fp matcher
	 */
	void olaf_fp_matcher_print_results(Olaf_FP_Matcher * olaf_fp_matcher);

	/**
	 * @brief      Free used memory and resources, does not close the database resources!
	 *
	 * @param      olaf_fp_matcher  The olaf fp matcher
	 */
	void olaf_fp_matcher_destroy(Olaf_FP_Matcher * olaf_fp_matcher);

#endif // OLAF_FP_MATCHER_H
