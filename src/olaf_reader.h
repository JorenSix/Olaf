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
 * @file olaf_reader.h
 *
 * @brief Reads audio samples from a file in blocks of samples with a certain overlap.
 *
 * The configuration determines the block sizes and overlap between blocks.
 */

#ifndef OLAF_READER_H
#define OLAF_READER_H

    #include "olaf_config.h"
    

    /**
     * @struct Olaf_Reader
     * @brief The state information. 
     * 
     * A struct to keep the internal state of the matcher hidden and should 
     * not be used in other places
     */
    typedef struct Olaf_Reader Olaf_Reader;

    /**
     * @brief      Create a new reader
     *
     * @param      config  The configuration
     * @param[in]  source  The path of the audio file. The audio file should be a raw mono file of a certain format.
     *
     * @return     A struct with internal state.
     */
    Olaf_Reader * olaf_reader_new(Olaf_Config * config,const char * source);

    /**
     * @brief      Read an audio block with overlap.
     *
     * @param      olaf_reader  The olaf reader
     * @param      block        An array to store the audio samples.
     *  
     * @return     The number of samples read.
     */
    size_t olaf_reader_read(Olaf_Reader * olaf_reader,float * block);

    /**
     * @brief      Returns the number of samples read.
     *
     * @param      olaf_reader  The olaf reader state.
     *
     * @return     The number of samples read in total.
     */
    size_t olaf_reader_total_samples_read(Olaf_Reader * olaf_reader);

    /**
     * @brief      Free resources related to the reader.
     *
     * @param      olaf_reader  The olaf reader state.
     */
    void olaf_reader_destroy(Olaf_Reader * olaf_reader);


#endif // OLAF_READER_H
