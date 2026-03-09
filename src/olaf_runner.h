// Olaf: Overly Lightweight Acoustic Fingerprinting
// Copyright (C) 2019-2025  Joren Six

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
 * @file olaf_runner.h
 *
 * @brief Helps to run query, store, delete or print commands. These share a lot of functionality but differ in crucial parts.
 * To keep this organized the runner keeps some shared state.
 */

#ifndef OLAF_RUNNER_H
#define OLAF_RUNNER_H

	#include "olaf_config.h"
	#include "olaf_db.h"
	#include "pffft.h"
	
	#define OLAF_RUNNER_MODE_QUERY  233
	#define OLAF_RUNNER_MODE_STORE  434
	#define OLAF_RUNNER_MODE_DELETE 653
	#define OLAF_RUNNER_MODE_PRINT  9043
	#define OLAF_RUNNER_MODE_CACHE  2342
	

	
	/**
	 * @struct Olaf_Runner
	 * 
	 * @brief Helps to run query, store, delete or print commands. These share a lot of functionality but differ in crucial parts.
	 * To keep this organized the runner keeps some shared state.
	 */
	typedef struct Olaf_Runner Olaf_Runner;

	struct Olaf_Runner{
		//the olaf configuration
		Olaf_Config * config;

		int mode;

		//The database	
		Olaf_DB* db;

		//The fft struct that is reused
		PFFFT_Setup *fftSetup;

		//In and output fft data
		float *fft_in;
		float *fft_out;

		//Cache file for printing fingerprints to if in PRINT or CACHE mode
		FILE * fp_cache_file;
		FILE * fp_meta_file;
	};

	/**
	 * @brief      Create a new runner
	 *
	 * @param[in]  mode  The mode
	 * @param[in]  config  The configuration
	 * @param[in]  output_cache_file  The output cache file
	 *
	 * @return     A new runner struct state of the runner
	 */
	Olaf_Runner * olaf_runner_new(int mode, Olaf_Config * config, FILE * fp_cache_file, FILE * fp_meta_file);

	/**
	 * @brief      Delete the resources related to the runner.
	 *
	 * @param      runner  The runner state to clear.
	 */
	void olaf_runner_destroy(Olaf_Runner * runner);

#endif //OLAF_RUNNER_H
