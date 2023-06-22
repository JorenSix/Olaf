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
#include <assert.h>

#include "olaf_max_filter.h"

//these are computed to allow +-1000 cents (almost an octave)
//the first zeros mean that the lower bins are ignored up until about 110Hz
//This assumes also 16kHz sample rate
const size_t olaf_max_filter_perceptual_min_idx[] = {0,0,0,0,0,0,0,0,0,9,9,9,9,9,9,9,9,10,10,11,12,12,12,13,14,14,14,15,15,16,16,17,17,18,19,19,19,21,21,22,22,23,23,25,25,25,26,26,26,27,27,27,29,29,29,31,31,31,33,33,33,35,35,35,35,37,37,37,37,39,39,39,39,41,41,41,41,43,43,43,43,43,47,47,47,47,47,51,51,51,51,51,53,53,53,53,53,55,55,55,55,55,55,59,59,59,59,59,59,63,63,63,63,63,63,63,67,67,67,67,67,67,67,71,71,71,71,71,71,71,75,75,75,75,75,75,75,75,79,79,79,79,79,79,79,79,83,83,83,83,83,83,83,83,83,87,87,87,87,87,87,87,87,87,95,95,95,95,95,95,95,95,95,95,99,99,99,99,99,99,99,99,99,99,103,103,103,103,103,103,103,103,103,103,103,111,111,111,111,111,111,111,111,111,111,111,111,119,119,119,119,119,119,119,119,119,119,119,119,127,127,127,127,127,127,127,127,127,127,127,127,127,135,135,135,135,135,135,135,135,135,135,135,135,135,135,143,143,143,143,143,143,143,143,143,143,143,143,143,143,151,151,151,151,151,151,151,151,151,151,151,151,151,151,151,151,159,159,159,159,159,159,159,159,159,159,159,159,159,159,159,159,167,167,167,167,167,167,167,167,167,167,167,167,167,167,167,167,167,167,175,175,175,175,175,175,175,175,175,175,175,175,175,175,175,175,175,175,191,191,191,191,191,191,191,191,191,191,191,191,191,191,191,191,191,191,191,199,199,199,199,199,199,199,199,199,199,199,199,199,199,199,199,199,199,199,199,199,207,207,207,207,207,207,207,207,207,207,207,207,207,207,207,207,207,207,207,207,207,207,223,223,223,223,223,223,223,223,223,223,223,223,223,223,223,223,223,223,223,223,223,223,223,239,239,239,239,239,239,239,239,239,239,239,239,239,239,239,239,239,239,239,239,239,239,239,239,239,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,271,271,271,271,271,271,271,271,271,271,271,271,271,271,271,271,271,271,271,271,271,271,271,271,271,271,271,287,287,287,287,287,287,287,287,287,287,287,287,287,287,287,287,287,287,287,287,287};
const size_t olaf_max_filter_perceptual_max_idx[] = {0,0,0,0,0,0,0,0,0,16,18,19,22,23,26,27,29,31,33,35,37,37,39,41,43,43,47,51,51,53,53,55,55,59,63,63,63,67,67,71,71,75,75,79,79,79,83,83,83,87,87,87,95,95,95,99,99,99,103,103,103,111,111,111,111,119,119,119,119,127,127,127,127,135,135,135,135,143,143,143,143,143,151,151,151,151,151,159,159,159,159,159,167,167,167,167,167,175,175,175,175,175,175,191,191,191,191,191,191,199,199,199,199,199,199,199,207,207,207,207,207,207,207,223,223,223,223,223,223,223,239,239,239,239,239,239,239,239,255,255,255,255,255,255,255,255,271,271,271,271,271,271,271,271,271,287,287,287,287,287,287,287,287,287,303,303,303,303,303,303,303,303,303,303,319,319,319,319,319,319,319,319,319,319,335,335,335,335,335,335,335,335,335,335,335,351,351,351,351,351,351,351,351,351,351,351,351,383,383,383,383,383,383,383,383,383,383,383,383,399,399,399,399,399,399,399,399,399,399,399,399,399,415,415,415,415,415,415,415,415,415,415,415,415,415,415,447,447,447,447,447,447,447,447,447,447,447,447,447,447,479,479,479,479,479,479,479,479,479,479,479,479,479,479,479,479,495,495,495,495,495,495,495,495,495,495,495,495,495,495,495,495,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512,512};

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

size_t olaf_max_filter_min(size_t a, size_t b){
    if(a<b)
        return a;
    return b;
}

float olaf_max_filter_max(float a, float b){
    if(a>b)
        return a;
    return b;
}


//https://github.com/lemire/runningmaxmin/blob/master/runningmaxmin.h#L80
//This is made available under LGPL.
void olaf_max_filter_van_herk_gil_werman(float * array, size_t array_size, size_t width,float * maxvalues){
        float R[width];
        float S[width];
    
        for (size_t j = 0; j < array_size - width + 1; j += width) {
            size_t Rpos = olaf_max_filter_min(j + width - 1, (array_size - 1));
            R[0] = array[Rpos];
            for (size_t i = Rpos - 1; i + 1 > j; i -= 1)
                R[Rpos - i] = olaf_max_filter_max(R[Rpos - i - 1], array[i]);
            S[0] = array[Rpos];
            
            size_t m1 = olaf_max_filter_min(j + 2 * width - 1, array_size);
            for (size_t i = Rpos + 1; i < m1; ++i) {
                S[i - Rpos] = olaf_max_filter_max(S[i - Rpos - 1], array[i]);
            }
            for (size_t i = 0; i < m1 - Rpos; i += 1)
                maxvalues[j + i] = olaf_max_filter_max(S[i], R[(Rpos - j + 1) - i - 1]);
        }
}


void olaf_max_filter(float* array, size_t array_size , size_t filter_width , float* maxvalues){
    
    //filter width is ignored, the frequency steps encoded in
    //the min max freq index above are used to have a more perceptually sound distance measure over the
    //frequceny range (of about an octave)
    (void)(filter_width);

    //this filter only works for 512 sized arrays
    assert(array_size == 512);

    //for speed, there is a limit on the number of bins to
    //evaluate
    size_t van_herk_filter_width = 103;
    
    //the naive implementation has a changing and small filter width
    //it is not that easy to optimize. From this bin on the filter is replaced
    //by a filter with a fixed width starting from this bin
    size_t naive_implementation_stop_bin = 82;
    
    //only start from frequency bin 9 (120Hz) and stop at the configured bin
    for(size_t f = 9 ;  f < naive_implementation_stop_bin ; f++ ){
        size_t startIndex = olaf_max_filter_perceptual_min_idx[f];
        size_t stopIndex = olaf_max_filter_perceptual_max_idx[f];

        //we assume the naive implementation
        assert(stopIndex - startIndex < van_herk_filter_width );

        //find the max value in the range
        float maxValue = -1000000;
        for(size_t j = startIndex ; j < stopIndex; j++){
            if(maxValue < array[j]){
                maxValue = array[j];
            }
        }

        //store the max value in place
        maxvalues[f] = maxValue;
    }
    
    //max filter the remaining values using the van herk max filter, with a fixed filter width
    
    float * max_values_shifted = &maxvalues[naive_implementation_stop_bin + (van_herk_filter_width/2)];
    float * to_filter = &array[naive_implementation_stop_bin];
    size_t to_filter_size = array_size  - naive_implementation_stop_bin;
    
    olaf_max_filter_van_herk_gil_werman(to_filter, to_filter_size, van_herk_filter_width,max_values_shifted);
}
