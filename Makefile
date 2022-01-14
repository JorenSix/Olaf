#Compiles the default olaf version for use on traditional computers
OLAF_COMMON_OBJ= \
  pffft.o \
  midl.o \
  mdb.o \
  hash-table.o \
  olaf.o \
  olaf_fp_file_writer.o \
  olaf_ep_extractor.o \
  olaf_fp_extractor.o \
  olaf_reader_stream.o \
  olaf_runner.o \
  olaf_stream_processor.o \
  olaf_fp_matcher.o \
  olaf_config.o 

OLAF_DISK_OBJ= \
  $(OLAF_COMMON_OBJ) \
  olaf_fp_db_writer.o \
  olaf_db.o

OLAF_MEM_OBJ= \
  $(OLAF_COMMON_OBJ) \
  olaf_fp_db_writer_mem.o \
  olaf_db_mem.o

CFLAGS= -g -W -Wall -std=c11 -pedantic -O2
LINK_FLAGS= -g -lc -lm -ffast-math -pthread

# pfft needs M_PI and other constants not in the ANSI C standard
pffft.o: src/pffft.c
	$(CC) -o $@ -c -std=gnu11 -g -W -Wall -pedantic -O2 $< 

%.o: src/%.c
	$(CC) -o $@ -c $(CFLAGS) $< 

bin/olaf_c: $(OLAF_DISK_OBJ)
	mkdir -p bin
	$(CC) -o $@ $(OLAF_DISK_OBJ) $(LINK_FLAGS)

bin/olaf_mem: $(OLAF_MEM_OBJ)
	mkdir -p bin
	$(CC) -o $@ $(OLAF_MEM_OBJ) $(LINK_FLAGS)

OLAF_TEST_OBJS = olaf_config.o olaf_reader_stream.o  olaf_tests.o midl.o mdb.o olaf_db.o

olaf_tests.o: tests/olaf_tests.c
	$(CC) -o $@ $(OLAF_DISK_OBJ) $(LINK_FLAGS)

bin/olaf_tests: $(OLAF_TEST_OBJS)
	mkdir -p bin
	mkdir -p tests/olaf_test_db
	rm -f tests/olaf_test_db/*
	$(CC) -o $@ $(OLAF_MEM_OBJ) $(LINK_FLAGS)

EMSCRIPTEN_FLAGS=-s WASM=1 -s ALLOW_MEMORY_GROWTH=1 -s EXPORTED_FUNCTIONS="['_malloc','_free']" -s EXPORTED_RUNTIME_METHODS='["cwrap"]'
EMSCRIPTEN_CC_FLAGS=-O3 -Wall -lm -lc -W -I.
OLAF_WASM_SRC = src/olaf_wasm.c \
  src/pffft.c \
  src/hash-table.c \
  src/olaf_ep_extractor.c \
  src/olaf_fp_extractor.c \
  src/olaf_db_mem.c \
  src/olaf_fp_db_writer_mem.c \
  src/olaf_fp_matcher.c \
  src/olaf_config.c

wasm/js/olaf.html:
	emcc -o $@ \
		$(EMSCRIPTEN_FLAGS)  \
		$(OLAF_WASM_SRC) \
		$(EMSCRIPTEN_CC_FLAGS)

# targets below are not real files
.PHONY: clean test compile destroy_db install uninstall

compile: bin/olaf_c

mem: bin/olaf_mem

test: bin/olaf_tests

web: wasm/js/olaf.html

clean:
	-rm -f *.o
	-rm -f bin/*
	-rm -f wasm/js/olaf.js
	-rm -f wasm/js/olaf.html
	-rm -f wasm/js/olaf.wasm

#Deletes the database, check your configuration
destroy_db:
	rm ~/.olaf/db/*

#Installs olaf on its default location
install:
	mkdir -p ~/.olaf/db/
	sudo cp bin/olaf_c /usr/local/bin/olaf_c
	sudo chmod +x /usr/local/bin/olaf_c
	sudo cp olaf.rb /usr/local/bin/olaf
	sudo chmod +x /usr/local/bin/olaf

#removes all installed files
uninstall:
	rm -r ~/.olaf
	sudo rm /usr/local/bin/olaf /usr/local/bin/olaf_c