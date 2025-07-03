// Olaf: Overly Lightweight Acoustic Fingerprinting
// Copyright (C) 2019-2025  Joren Six

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
 * @brief A double ended queue interface.
 *
 * This hides the underlying dequeue implementation used and gives a stable
 * and simple interface for use in Olaf. It also manages memory related to the deque. 
 * Additionally, it adds a level of indirection which might come in handy to replace the underlying
 * implementation.
 */
#ifndef OLAF_DEQUE
#define OLAF_DEQUE
	
	/**
	 * @struct Olaf_Deque
	 *
	 * @brief Contains state information related to the deque.
	 * 
	 * The memory used by the ep extractor should be freed in the  @_destroy@ method. 
	 */
	typedef struct Olaf_Deque Olaf_Deque;

	/**
	 * @brief      Create an new double ended queue 
	 *
	 * @param[in]  size  The maximum size of de deque. Memory is allocated on initialization.
	 *
	 * @return     The state of the deque.
	 */
	Olaf_Deque * olaf_deque_new(size_t size);

	/**
	 * @brief      Push a value to the end of the deque.
	 *
	 * @param      olaf_deque  The olaf deque
	 * @param[in]  value       The value
	 */
	void olaf_deque_push_back(Olaf_Deque * olaf_deque,size_t value);

	/**
	 * @brief      Return the back of the deque.
	 *
	 * @param      olaf_deque  The olaf deque
	 *
	 * @return     The back, tail of the deque
	 */
	size_t olaf_deque_back(Olaf_Deque * olaf_deque);

	/**
	 * @brief      Checks if the deque is empty.
	 *
	 * @param      olaf_deque  The olaf deque
	 *
	 * @return     True if the deque is empty
	 */
	bool olaf_deque_empty(Olaf_Deque * olaf_deque);

	/**
	 * @brief      The front of the deque.
	 *
	 * @param      olaf_deque  The olaf deque
	 *
	 * @return     The front of the deque.
	 */
	size_t olaf_deque_front(Olaf_Deque * olaf_deque);

	/**
	 * @brief      Pop the back from the deque.
	 *
	 * @param      olaf_deque  The olaf deque
	 */
	void olaf_deque_pop_back(Olaf_Deque * olaf_deque);

	/**
	 * @brief      Remove the front of the deque.
	 *
	 * @param      olaf_deque  The olaf deque
	 */
	void olaf_deque_pop_front(Olaf_Deque * olaf_deque);

	/**
	 * @brief      Free resources and memory related to the deque.
	 *
	 * @param      olaf_deque  The olaf deque
	 */
	void olaf_deque_destroy(Olaf_Deque * olaf_deque);


#endif // OLAF_DEQUE
