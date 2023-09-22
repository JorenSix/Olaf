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
	 * @brief Callback function template to respond to a result.
	 *
	 * @param matchCount         The number of matches. If zero, this means an empty result.
	 * @param queryStart         The match start time, in seconds,  in the query.
	 * @param queryStop          The match end time, in seconds, of the query fingerprint.
	 * @param path               The path of the matched resource.
	 * @param matchIdentifier    The identifier of the matched audio file.
	 * @param referenceStart     The match start time, in seconds, of the reference fingerprint.
	 * @param referenceStop      The match end time, in seconds, of the reference fingerprint.
	 */
	typedef void (*Olaf_FP_Matcher_Result_Callback)(int matchCount, float queryStart, float queryStop, const char* path, uint32_t matchIdentifier, float referenceStart, float referenceStop);
	
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
	Olaf_FP_Matcher * olaf_fp_matcher_new(Olaf_Config * config,Olaf_DB* db,Olaf_FP_Matcher_Result_Callback callback );
	
	//Matches fingerprints to the database and updates internal state
	
	/**
	 * @brief      Match fingerprints with the database.
	 *
	 * @param      olaf_fp_matcher  The olaf fp matcher
	 * @param      olaf_fps         The fingerprints
	 */
 	void olaf_fp_matcher_match(Olaf_FP_Matcher * olaf_fp_matcher, struct extracted_fingerprints * olaf_fps);
	
	/**
	 * @brief      Print a header for the CSV output.
	 */
	void olaf_fp_matcher_callback_print_header(void);

	/**
	 * @brief Prints a match result using the specified format.
	 *
	 * This function is an example of a callback function that can be used with
	 * `olaf_fp_matcher_callback_print_results`. It prints a single match result in a
	 * specific format.
	 *
	 * @param matchCount         The number of matches.
	 * @param queryStart         The match start time, in seconds,  in the query.
	 * @param queryStop          The match end time, in seconds, of the query fingerprint.
	 * @param path               The path of the matched resource.
	 * @param matchIdentifier    The identifier of the matched audio file.
	 * @param referenceStart     The match start time, in seconds, of the reference fingerprint.
	 * @param referenceStop      The match end time, in seconds, of the reference fingerprint.
	 */
	void olaf_fp_matcher_callback_print_result(int matchCount, float queryStart, float queryStop, const char* path, uint32_t matchIdentifier, float referenceStart, float referenceStop);

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
