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
#include <stdbool.h>

#include "olaf_max_filter.h"

void olaf_max_filter_naive(float* array, size_t array_size , size_t filter_width , float* maxvalues){
    size_t half_filter_width = filter_width / 2;
    for(size_t i = 0 ; i < array_size; i++){
        size_t startIndex = i - half_filter_width > 0 ? i - half_filter_width : 0;
        size_t stopIndex = i + half_filter_width < array_size ? i + half_filter_width + 1: array_size;
        maxvalues[i] = -100000;
        for(size_t j = startIndex ; j < stopIndex; j++){
            if(array[j]>maxvalues[i])
                maxvalues[i]=array[j];
        }
    }
}

void olaf_max_filter(float* array, size_t array_size , size_t filter_width , float* maxvalues){
    olaf_max_filter_naive(array, array_size , filter_width , maxvalues);
}

