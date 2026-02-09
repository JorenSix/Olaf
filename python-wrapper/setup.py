import sys, glob, re, os
from cffi import FFI

ffibuilder = FFI()

# Get absolute paths for the project
project_root = os.path.abspath(os.path.dirname(__file__) + '/..')
bin_dir = os.path.join(project_root, 'bin')

# Set up the C source with includes and library linking
header_files = glob.glob("./src/*.h", recursive=True)
includes = [f'#include "{hf}"' for hf in header_files]

ffibuilder.set_source("olaf_cffi", "\n".join(includes),
    libraries=['c', 'm', 'olaf'],
    library_dirs=[bin_dir],
    extra_link_args=[f'-Wl,-rpath,{bin_dir}'])

# Headers to parse for CFFI
supported_headers = [
    "./src/olaf_config.h",
    "./src/olaf_resource_meta_data.h",
    "./src/olaf_ep_extractor.h",
    "./src/olaf_fp_extractor.h",
    "./src/olaf_db.h",
    "./src/olaf_fp_matcher.h",
    "./src/olaf_fp_db_writer.h",
    "./src/olaf_fft.h"
]

# Read and preprocess headers
data = ""
for header_file in supported_headers:
    with open(header_file) as f:
        content = f.read()

        # Remove preprocessor directives
        content = re.sub(r'^\s*#.*$', '', content, flags=re.MULTILINE)

        # Remove comments (both // and /* */)
        content = re.sub(r'//.*$', '', content, flags=re.MULTILINE)
        content = re.sub(r'/\*.*?\*/', '', content, flags=re.DOTALL)

        # Remove header guards and empty lines
        content = re.sub(r'^\s*$\n', '', content, flags=re.MULTILINE)

        data += content + "\n"

# Add necessary type definitions and the Python callback
cffi_header = """
// Standard types that CFFI needs defined
typedef ... FILE;
typedef unsigned char bool;
typedef unsigned int uint32_t;
typedef unsigned long long uint64_t;
typedef unsigned short uint16_t;
typedef unsigned char uint8_t;
typedef int int32_t;
typedef long long int64_t;
typedef short int16_t;
typedef signed char int8_t;
typedef unsigned long size_t;

// Python callback for results
extern "Python" void olaf_python_wrapper_handle_result(
    int matchCount,
    float queryStart,
    float queryStop,
    const char* path,
    uint32_t matchIdentifier,
    float referenceStart,
    float referenceStop
);

"""

# Combine everything
final_cdef = cffi_header + data

# Debug: save the processed header to a file for inspection
with open("python-wrapper/cffi_debug.h", "w") as f:
    f.write(final_cdef)

try:
    ffibuilder.cdef(final_cdef)
except Exception as e:
    print("Error parsing headers. Debug output saved to python-wrapper/cffi_debug.h")
    print(f"Error: {e}")
    sys.exit(1)

if __name__ == "__main__":
    ffibuilder.compile(verbose=True)

    # Fix the library path on macOS using install_name_tool
    if sys.platform == 'darwin':
        import subprocess
        import glob as glob_module

        # Find the compiled module
        so_files = glob_module.glob('./olaf_cffi.cpython-*.so')
        if so_files:
            so_file = so_files[0]
            print(f"\nFixing library path in {so_file}...")

            # Change relative library path to absolute
            subprocess.run([
                'install_name_tool',
                '-change',
                'bin/libolaf.so',
                f'{bin_dir}/libolaf.so',
                so_file
            ], check=True)

            print(f"Library path fixed. Module ready to use!")
