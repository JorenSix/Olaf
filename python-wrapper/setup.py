import sys, glob

from cffi import FFI
ffibuilder = FFI()

header_files = glob.glob("./src/*h", recursive=True)

extra_methods = r"""

"""

includes = []
for header_file in header_files:
	includes.append("#include \"" + header_file +  "\"")

ffibuilder.set_source("olaf_cffi", "\n".join(includes) + extra_methods, 
		libraries=['c','m','olaf'],
		library_dirs=['./bin/'])

#include "olaf_fp_matcher.h"
#include "olaf_fp_db_writer.h"
#
supported_headers = ["./src/olaf_config.h",
"./src/olaf_ep_extractor.h",
"./src/olaf_fp_extractor.h",
"./src/olaf_db.h",
"./src/olaf_fp_matcher.h",
"./src/olaf_fp_db_writer.h",
"./src/olaf_fft.h"]


data = ""
for header_file in supported_headers:
	with open(header_file) as f:
		data += ''.join([line for line in f if not line.strip().startswith('#')])

ffibuilder.cdef(data)

if __name__ == "__main__":
    ffibuilder.compile(verbose=True)