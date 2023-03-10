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
// along with this program.  If not, see <https://www.gnu.org/licenses/>.s
#include <stdlib.h>
#include <stdio.h>
#include <math.h>
#include <stdbool.h>

#include "queue.h"
#include "olaf_deque.h"

//state information
struct Olaf_Deque{
	size_t max_size;
	size_t * values;
	size_t value_index;
	Queue *queue;
};

Olaf_Deque * olaf_deque_new(size_t max_size){
	Olaf_Deque * olaf_deque = (Olaf_Deque *) malloc(sizeof(Olaf_Deque));
	olaf_deque->max_size = max_size;
	olaf_deque->value_index = 0;
	olaf_deque->values = (size_t *) calloc(olaf_deque->max_size ,sizeof(size_t));
	olaf_deque->queue = queue_new();
	return olaf_deque;
}

//free memory resources and 
void olaf_deque_destroy(Olaf_Deque * olaf_deque){
	queue_free(olaf_deque->queue);
	//free(olaf_deque->values);
	free(olaf_deque);
}

void olaf_deque_push_back(Olaf_Deque * olaf_deque,size_t value){
	olaf_deque->values[olaf_deque->value_index]=value;
	queue_push_tail(olaf_deque->queue, &olaf_deque->values[olaf_deque->value_index]);
	olaf_deque->value_index++;
	//grow array here if needed
	if (olaf_deque->value_index == olaf_deque->max_size){
		fprintf(stderr,"Growing array to grow array !\n");
	}
}

size_t olaf_deque_back(Olaf_Deque * olaf_deque){
	size_t * value = (size_t *) queue_peek_tail(olaf_deque->queue);
	return *(value); 
}

size_t olaf_deque_front(Olaf_Deque * olaf_deque){
	size_t * value = (size_t *) queue_peek_head(olaf_deque->queue);
	return *(value); 
}

bool olaf_deque_empty(Olaf_Deque * olaf_deque){
	return queue_is_empty(olaf_deque->queue);
}

void olaf_deque_pop_back(Olaf_Deque * olaf_deque){
	queue_pop_tail(olaf_deque->queue);
}

void olaf_deque_pop_front(Olaf_Deque * olaf_deque){
	queue_pop_head(olaf_deque->queue);
}

