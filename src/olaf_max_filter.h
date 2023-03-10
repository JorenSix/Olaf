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
 * @file olaf_max_filter.h
 *
 * @brief Max filter interface to experiment with differen max filter implementations.
 *
 */

#ifndef OLAF_MAX_FILTER
#define OLAF_MAX_FILTER

#include <stdio.h>
#include <math.h>

/**
 * @brief      A naive max filter implementation for reference.
 *
 * @param      array         The array.
 * @param[in]  array_size    The array size.
 * @param[in]  filter_width  The max filter width.
 * @param      maxvalues     The array of values to filter.
 */
void olaf_max_filter_naive(float* array, size_t array_size , size_t filter_width , float* maxvalues );

/**
 * @brief      An other, preferably faster, implementation.
 *
 * @param      array         The array.
 * @param[in]  array_size    The array size.
 * @param[in]  filter_width  The filter width.
 * @param      maxvalues     The array of values to filter.
 */
void olaf_max_filter(float* array, size_t array_size , size_t filter_width , float* maxvalues );

#endif // OLAF_MAX_FILTER
