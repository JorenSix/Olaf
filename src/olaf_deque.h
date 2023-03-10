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
 * @file olaf_deque.h
 *
 * @brief Olaf double ended queue interface.
 *
 * This hides the underlying deque implementation used and gives a stable
 * and simple interface for use in olaf. It just adds a level of indirection
 * which might come in handy.
 */
#ifndef OLAF_DEQUE
#define OLAF_DEQUE
	

	typedef struct Olaf_Deque Olaf_Deque;

	Olaf_Deque * olaf_deque_new(size_t size);

	void olaf_deque_push_back(Olaf_Deque * olaf_deque,size_t value);

	size_t olaf_deque_back(Olaf_Deque * olaf_deque);

	bool olaf_deque_empty(Olaf_Deque * olaf_deque);

	size_t olaf_deque_front(Olaf_Deque * olaf_deque);

	void olaf_deque_pop_back(Olaf_Deque * olaf_deque);

	void olaf_deque_pop_front(Olaf_Deque * olaf_deque);

	//free memory resources and 
	void olaf_deque_destroy(Olaf_Deque * olaf_deque);


#endif // OLAF_DEQUE
