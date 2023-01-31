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
#ifndef OLAF_DEQUE
#define OLAF_DEQUE
	
	typedef struct Olaf_Deque Olaf_Deque;

	Olaf_Deque * olaf_deque_new(size_t size);

	void olaf_deque_push_back(Olaf_Deque *,size_t value);

	size_t olaf_deque_back(Olaf_Deque *);

	bool olaf_deque_empty(Olaf_Deque *);

	size_t olaf_deque_front(Olaf_Deque *);

	void olaf_deque_pop_back(Olaf_Deque *);

	void olaf_deque_pop_front(Olaf_Deque *);

	//free memory resources and 
	void olaf_deque_destroy(Olaf_Deque *);


#endif // OLAF_DEQUE
