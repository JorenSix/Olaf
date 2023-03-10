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
 * @file olaf_max_lemire.c
 *
 * @brief Lemire Max filter implementation. 
 * 
 * See https://github.com/lemire/runningmaxmin/blob/master/runningmaxmin.h, Available under LGPL.
 * 
 * Daniel Lemire, Streaming Maximum-Minimum Filter Using No More than Three Comparisons per Element. Nordic Journal of Computing, 13 (4), pages 328-339, 2006.
 * 
 */

#include <stdbool.h>

#include "olaf_max_filter.h"
#include "olaf_deque.h"


void olaf_lemire_max_filter(float* array, size_t array_size , size_t filter_width , float* maxvalues ) {

    Olaf_Deque * maxfifo = olaf_deque_new(array_size * 5);
    olaf_deque_push_back(maxfifo,0);
        
    for (size_t i = 1; i < filter_width; ++i) {
        if (array[i] > array[i - 1]) { // overshoot
            olaf_deque_pop_back(maxfifo);
            while (!olaf_deque_empty(maxfifo)) {
                if (array[i] <= array[olaf_deque_back(maxfifo)])
                    break;
                olaf_deque_pop_back(maxfifo);
            }
        }
        olaf_deque_push_back(maxfifo,i);
    }
    for (size_t i = filter_width; i < array_size; ++i) {
        maxvalues[i - filter_width] = array[olaf_deque_front(maxfifo)];
        if (array[i] > array[i - 1]) { // overshoot
            olaf_deque_pop_back(maxfifo);
            while (!olaf_deque_empty(maxfifo)) {
                if (array[i] <= array[olaf_deque_back(maxfifo)])
                    break;
                olaf_deque_pop_back(maxfifo);
            }
        }
        olaf_deque_push_back(maxfifo,i);
        if (i == filter_width + olaf_deque_front(maxfifo))
            olaf_deque_pop_front(maxfifo);
    }
    maxvalues[array_size - filter_width] = array[olaf_deque_front(maxfifo)];

      //free the queue
    olaf_deque_destroy(maxfifo);
}

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

    olaf_lemire_max_filter(array, array_size , filter_width , maxvalues);

    //make max values as long as input
    size_t half_filter_width = filter_width / 2;
    
    //shift the filtered values to match the original indexes
    for(size_t i = array_size - 1 ; i >= half_filter_width  ; i--){
        maxvalues[i] = maxvalues[i-(half_filter_width) ];
    }

    //the last part is clamped to the last value
    //These are values not that relevant for human hearing (+4000Hz)
    for(size_t i = array_size - 1 ; i >= array_size - half_filter_width ; i--){
        maxvalues[i] = maxvalues[array_size - half_filter_width -1];
    }

    //The lower (starting from 100Hz) are more relevant
    //filter with a smaller filter
    /*
    //basically ignore the first 3 bands
    for(size_t i = 0 ; i < 3;i++){
        maxvalues[i] = -1.0;
    }

    for(size_t i = 3 ; i < half_filter_width;i++){
        size_t startIndex = (i - 5) > 0 ? (i - 5) : 0;
        size_t filter_width_forward = (2 * i + 13) > half_filter_width ? (2 * i + 13)  : half_filter_width;
        size_t stopIndex =  i + half_filter_width;
        maxvalues[i] = -100000;
        for(size_t j = startIndex ; j < stopIndex; j++){
            if(array[j]>maxvalues[i]) maxvalues[i]=array[j];
        }
    }
    */
    for(size_t i = 0 ; i < half_filter_width;i++){
        size_t startIndex =  0;
        size_t stopIndex =  i + half_filter_width;
        maxvalues[i] = -100000;
        for(size_t j = startIndex ; j < stopIndex; j++){
            if(array[j]>maxvalues[i]) maxvalues[i]=array[j];
        }
    }
}

