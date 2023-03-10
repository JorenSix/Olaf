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
#ifndef OLAF_STREAM_PROCESSOR_H
#define OLAF_STREAM_PROCESSOR_H

    #include "olaf_config.h"
    #include "olaf_runner.h"

    typedef struct Olaf_Stream_Processor Olaf_Stream_Processor;

    Olaf_Stream_Processor * olaf_stream_processor_new(Olaf_Runner * runner,const char* raw_path,const char* orig_path);

    void olaf_stream_processor_process(Olaf_Stream_Processor * olaf_stream_processor);

    // free up memory and release resources
    void olaf_stream_processor_destroy(Olaf_Stream_Processor * olaf_stream_processor);

#endif // OLAF_STREAM_PROCESSOR_H
