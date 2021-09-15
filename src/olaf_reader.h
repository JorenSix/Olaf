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
#ifndef OLAF_READER_H
#define OLAF_READER_H

    #include "olaf_config.h"

    typedef struct Olaf_Reader Olaf_Reader;

    Olaf_Reader * olaf_reader_new(Olaf_Config * config,const char * source);

    size_t olaf_reader_read(Olaf_Reader *,float *);

    size_t olaf_reader_total_samples_read(Olaf_Reader *);

    // free up memory and release resources
    void olaf_reader_destroy(Olaf_Reader * );


#endif // OLAF_READER_H
