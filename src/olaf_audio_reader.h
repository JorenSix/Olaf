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
#ifndef OLAF_AUDIO_READER_H
#define OLAF_AUDIO_READER_H

#include <stddef.h> // for size_t

//the PCM data of an audio file
struct olaf_audio {
	size_t fileSizeInSamples;
	float* audioData;
};


//reads a RAW audio file into a struct representing samples
void olaf_audio_reader_read(const char* filename,struct olaf_audio* audio);

#endif // OLAF_AUDIO_READER_H
