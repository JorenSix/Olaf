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
#ifndef OLAF_RUNNER_H
#define OLAF_RUNNER_H

	#include "olaf_config.h"
	#include "olaf_db.h"
	#include "pffft.h"
	
	
	#define OLAF_RUNNER_MODE_QUERY  233
	#define OLAF_RUNNER_MODE_STORE  434
	#define OLAF_RUNNER_MODE_DELETE 653
	#define OLAF_RUNNER_MODE_PRINT  9043

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
	};

	Olaf_Runner * olaf_runner_new(int mode);

	void olaf_runner_destroy(Olaf_Runner * runner);

#endif //OLAF_RUNNER_H
