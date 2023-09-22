
#Compiles the default olaf version for use on traditional computers
compile:
	gcc -c src/pffft.c 					-W -Wall -std=gnu11 -pedantic -O2 #pfft needs M_PI and other constants not in the ANSI c standard
	gcc -c src/midl.c 					-W -Wall -std=c11 -pedantic -O2
	gcc -c src/mdb.c 					-W -Wall -std=c11 -pedantic -O2
	gcc -c src/hash-table.c     		-W -Wall -std=c11 -pedantic -O2
	gcc -c src/queue.c  		   		-W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_deque.c  	   		-W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_max_filter_perceptual_van_herk.c	-W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf.c 					-W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_fp_file_writer.c 	-W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_db.c 				-W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_fp_db_writer.c 		-W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_fp_db_writer_cache.c -W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_ep_extractor.c 		-W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_fp_extractor.c 		-W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_reader_stream.c 	-W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_runner.c 			-W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_stream_processor.c 	-W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_fp_matcher.c 		-W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_config.c 			-W -Wall -std=c11 -pedantic -O2
	mkdir -p bin
	gcc -o bin/olaf_c *.o 			-lc -lm -ffast-math -pthread

lib:
	gcc -c src/pffft.c 					-W -Wall -std=gnu11 -pedantic -O2 #pfft needs M_PI and other constants not in the ANSI c standard
	gcc -c src/midl.c 					-W -Wall -std=c11 -pedantic -O2
	gcc -c src/mdb.c 					-W -Wall -std=c11 -pedantic -O2
	gcc -c src/hash-table.c     		-W -Wall -std=c11 -pedantic -O2
	gcc -c src/queue.c  		   		-W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_deque.c  	   		-W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_max_filter_perceptual_van_herk.c	-W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf.c 					-W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_fp_file_writer.c 	-W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_db.c 				-W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_fp_db_writer.c 		-W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_fp_db_writer_cache.c -W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_ep_extractor.c 		-W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_fp_extractor.c 		-W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_reader_stream.c 	-W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_runner.c 			-W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_stream_processor.c 	-W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_fp_matcher.c 		-W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_config.c 			-W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_fft.c 				-W -Wall -std=c11 -pedantic -O2
	mkdir -p bin
	gcc -o bin/libolaf.so *.o 			-lc -lm -ffast-math -pthread -shared

#A compilation with support for profiling
compile_gprof:
	gcc -c src/pffft.c 					-pg -W -Wall -std=gnu11 -pedantic -O2 #pfft needs M_PI and other constants not in the ANSI c standard
	gcc -c src/midl.c 					-pg -W -Wall -std=c11 -pedantic -O2
	gcc -c src/mdb.c 					-pg -W -Wall -std=c11 -pedantic -O2
	gcc -c src/hash-table.c     		-pg -W -Wall -std=c11 -pedantic -O2
	gcc -c src/queue.c  		   		-pg -W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_deque.c  	   		-pg -W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_max_filter_perceptual_van_herk.c	-pg -W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf.c 					-pg -W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_fp_file_writer.c 	-pg -W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_db.c 				-pg -W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_fp_db_writer.c 		-pg -W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_fp_db_writer_cache.c -pg -W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_ep_extractor.c 		-pg -W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_fp_extractor.c 		-pg -W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_reader_stream.c 	-pg -W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_runner.c 			-pg -W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_stream_processor.c 	-pg -W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_fp_matcher.c 		-pg -W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_config.c 			-pg -W -Wall -std=c11 -pedantic -O2
	mkdir -p bin
	gcc -o bin/olaf_c *.o 			-pg -lc -lm -ffast-math -pthread

#The memory database version is equal to the embedded version
#pass the -D to load the correct 
mem:
	gcc -c src/pffft.c 					 -Dmem -W -Wall -std=gnu11 -pedantic -O2 #pfft needs M_PI and other constants not in the ANSI c standard
	gcc -c src/hash-table.c     	 	 -Dmem -W -Wall -std=c11 -pedantic -O2
	gcc -c src/queue.c  		   		 -Dmem -W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_deque.c  	   		 -Dmem -W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_max_filter_perceptual_van_herk.c  -Dmem -W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf.c 					 -Dmem -W -Wall -std=gnu11 -pedantic -O2
	gcc -c src/olaf_db_mem.c 			 -Dmem -W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_fp_db_writer_mem.c 	 -Dmem -W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_fp_file_writer.c 	 -Dmem -W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_fp_db_writer_cache.c -Dmem -W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_runner.c 			 -Dmem -W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_stream_processor.c 	 -Dmem -W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_ep_extractor.c 		 -Dmem -W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_fp_extractor.c 		 -Dmem -W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_reader_stream.c		 -Dmem -W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_fp_matcher.c 		 -Dmem -W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_config.c 			 -Dmem -W -Wall -std=c11 -pedantic -O2
	mkdir -p bin
	gcc -o bin/olaf_mem *.o 			-lc -lm -ffast-math

#Compiles the webassembly version: it is similar to the mem version
web:
	emcc -o wasm/js/olaf.js \
		-s SINGLE_FILE=1 \
		-s ASSERTIONS=1 \
		-s ENVIRONMENT=shell \
		-s MODULARIZE=1  \
		-s WASM=1 \
		-s BINARYEN_ASYNC_COMPILATION=0 \
		--bind \
		-s ALLOW_MEMORY_GROWTH=1 \
		-s EXPORTED_FUNCTIONS="['_malloc','_free']" \
		-s EXPORTED_RUNTIME_METHODS='["cwrap"]' \
		src/olaf_wasm.c \
		src/pffft.c \
		src/hash-table.c \
		src/queue.c \
		src/olaf_deque.c \
		src/olaf_max_filter_perceptual_van_herk.c \
		src/olaf_ep_extractor.c \
		src/olaf_fp_extractor.c \
		src/olaf_db_mem.c \
		src/olaf_fp_db_writer_mem.c \
		src/olaf_fp_matcher.c \
		src/olaf_config.c  -O3 -Wall -lm -lc -W -I. -ffast-math
		cat wasm/js/olaf.js wasm/js/olaf_processor_edit.js > wasm/js/olaf_processor.js
		rm  wasm/js/olaf.js

#Cleans the temporary files
clean:
	-rm -f *.o
	-rm -f bin/*
	-rm -f wasm/js/olaf.js
	-rm -f wasm/js/olaf.html
	-rm -f wasm/js/olaf.wasm
	-rm -f olaf_cffi*

#Deletes the database, check your configuration for the database location
destroy_db:
	rm ~/.olaf/db/*

#Installs olaf on its default location
install:
	mkdir -p ~/.olaf/db/
	sudo mv bin/olaf_c /usr/local/bin/olaf_c
	sudo chmod +x /usr/local/bin/olaf_c
	sudo cp olaf.rb /usr/local/bin/olaf
	sudo chmod +x /usr/local/bin/olaf

#Only install the Ruby part, mainly for dev purposes
install_r:
	sudo cp olaf.rb /usr/local/bin/olaf
	sudo chmod +x /usr/local/bin/olaf

#installs olaf as root user
install-su:
	mkdir -p ~/.olaf/db/
	cp bin/olaf_c /usr/local/bin/olaf_c
	chmod +x /usr/local/bin/olaf_c
	cp olaf.rb /usr/local/bin/olaf
	chmod +x /usr/local/bin/olaf

#removes all installed files
uninstall:
	rm -r ~/.olaf
	sudo rm /usr/local/bin/olaf /usr/local/bin/olaf_c

#Compile unit tests and run the unit tests
#The functional tests are run via ruby, see readme
test:
	gcc -c src/olaf_config.c -W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_reader_stream.c -W -Wall -std=c11 -pedantic -O2
	gcc -c src/queue.c  		   		-W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_deque.c  	   		-W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_max_filter_naive.c -W -Wall -std=c11 -pedantic -O2
	gcc -c tests/olaf_tests.c	-Isrc	-W -Wall -std=c11 -pedantic -O2
	gcc -c src/midl.c 					-W -Wall -std=c11 -pedantic -O2
	gcc -c src/mdb.c 					-W -Wall -std=c11 -pedantic -O2
	gcc -c src/olaf_db.c 			-W -Wall -std=c11 -pedantic -O2
	mkdir -p bin
	gcc -o bin/olaf_tests *.o		-lc -lm -ffast-math
	mkdir -p tests/olaf_test_db
	- rm tests/olaf_test_db/*

#Generate doxygen API documentation
docs:
	doxygen

#Compile a windows exe using Zig
zig_win:
	zig build -Dtarget=x86_64-windows-gnu

#Compile a webassembly version, currently unused, via Zig
zig_web:
	zig build -Dtarget=wasm32-freestanding-musl -Drelease-small
	
