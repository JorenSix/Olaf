lib:
	gcc -c ../src/pffft.c 					-W -Wall -std=gnu11 -pedantic -O2 #pfft needs M_PI and other constants not in the ANSI c standard
	gcc -c ../src/midl.c 					-W -Wall -std=c11 -pedantic -O2
	gcc -c ../src/mdb.c 					-W -Wall -std=c11 -pedantic -O2
	gcc -c ../src/hash-table.c     			-W -Wall -std=c11 -pedantic -O2
	gcc -c ../src/queue.c  		   			-W -Wall -std=c11 -pedantic -O2
	gcc -c ../src/olaf_deque.c  	   		-W -Wall -std=c11 -pedantic -O2
	gcc -c ../src/olaf_max_filter_perceptual_van_herk.c	-W -Wall -std=c11 -pedantic -O2
	gcc -c ../src/olaf.c 					-W -Wall -std=c11 -pedantic -O2
	gcc -c ../src/olaf_fp_file_writer.c 	-W -Wall -std=c11 -pedantic -O2
	gcc -c ../src/olaf_db.c 				-W -Wall -std=c11 -pedantic -O2
	gcc -c ../src/olaf_fp_db_writer.c 		-W -Wall -std=c11 -pedantic -O2
	gcc -c ../src/olaf_fp_db_writer_cache.c -W -Wall -std=c11 -pedantic -O2
	gcc -c ../src/olaf_ep_extractor.c 		-W -Wall -std=c11 -pedantic -O2
	gcc -c ../src/olaf_fp_extractor.c 		-W -Wall -std=c11 -pedantic -O2
	gcc -c ../src/olaf_reader_stream.c 		-W -Wall -std=c11 -pedantic -O2
	gcc -c ../src/olaf_runner.c 			-W -Wall -std=c11 -pedantic -O2
	gcc -c ../src/olaf_stream_processor.c 	-W -Wall -std=c11 -pedantic -O2
	gcc -c ../src/olaf_fp_matcher.c 		-W -Wall -std=c11 -pedantic -O2
	gcc -c ../src/olaf_config.c 			-W -Wall -std=c11 -pedantic -O2
	gcc -c ../src/olaf_fft.c 				-W -Wall -std=c11 -pedantic -O2
	
	mkdir -p bin
	gcc -o bin/libolaf.so *.o 			-lc -lm -ffast-math -pthread -shared

clean:
	rm *.o