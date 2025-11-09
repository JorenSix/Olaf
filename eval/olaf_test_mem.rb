require_relative('olaf_result_line.rb')

REF_TARGET_FOLDER = "dataset/ref"
MEM_BINARY_LOCATION = "./bin/olaf_mem"

def assert(message, &block)
    unless block.call
        STDERR.puts "FAIL: #{message}"
        STDOUT.puts "FAIL: #{message}"
        exit -1
    else
        STDOUT.puts "PASS: #{message}"
    end
end

def check_and_download_dataset
  #check dataset, if not available, download
  ref_files = Dir.glob(File.join(REF_TARGET_FOLDER,"*mp3"))
  if ref_files.length == 0
      STDERR.puts 'Test dataset not found. Downloading...'
      system("ruby eval/olaf_download_dataset.rb")
  end
end
check_and_download_dataset()


system("make clean")
system("make mem")
sleep 0.1
puts "MEM_BINARY_LOCATION: #{MEM_BINARY_LOCATION}"

assert("Mem binary should exist!"){File.exist? MEM_BINARY_LOCATION}

# Find the specific test files we need
# Note: The mem version has limited capacity (~30 fingerprints, ~8-9 seconds)
# So we use the same file for both reference and query to test basic functionality
ref_file = Dir.glob(File.join(REF_TARGET_FOLDER, "*.mp3")).first

assert("At least one reference file should exist") { !ref_file.nil? }

# Convert reference file to raw using Zig CLI
system("zig build run -- to_raw '#{ref_file}'")
system("mkdir -p dataset/raw/ref")
system("mv olaf_audio_*.raw dataset/raw/ref/")

# Use the same file as query to test basic matching functionality
query_file = ref_file

# Copy the raw file to use as query
system("mkdir -p dataset/raw/queries")
system("cp dataset/raw/ref/*.raw dataset/raw/queries/")

# Find the converted raw files
raw_ref = Dir.glob("dataset/raw/ref/*.raw").first
assert("Converted reference raw file should exist") { !raw_ref.nil? && File.exist?(raw_ref) }

#create a new mem db
ref_identifier = File.basename(ref_file, File.extname(ref_file))
system("#{MEM_BINARY_LOCATION} store '#{raw_ref}' '#{ref_identifier}' > src/olaf_fp_ref_mem.h")
assert("Header file should be generated") { File.exist?("src/olaf_fp_ref_mem.h") && File.size("src/olaf_fp_ref_mem.h") > 0 }

system("make clean")
#compile a mem version with the new database
system("make mem")
assert("Mem binary should exist!"){File.exist? MEM_BINARY_LOCATION}

# Find the converted query raw file
raw_query = Dir.glob("dataset/raw/queries/*.raw").first
assert("Converted query raw file should exist") { !raw_query.nil? && File.exist?(raw_query) }

query_identifier = File.basename(query_file, File.extname(query_file))
cmd = `#{MEM_BINARY_LOCATION} query '#{raw_query}' '#{query_identifier}'`
assert("Query should produce output") { !cmd.nil? && cmd.length > 0 }

lines = cmd.split("\n").map{|l| "1,1, queryfile, 0, " + l }
lines = lines.drop(1)
lines = lines.map{|l| OlafResultLine.new(l) }.delete_if{|l| !l.valid}

assert("Query should return at least one valid match") { lines.length > 0 }
first_match = lines.first

# For the mem version, we're testing with the same file as both reference and query
# The mem version has limited capacity (~30 fingerprints, first 8-9 seconds)
# So we just verify that:
# 1. The correct file is matched
# 2. The time alignment is reasonable for the stored portion
ref_matched = File.basename(first_match.ref_path, File.extname(first_match.ref_path))

assert("Matched file #{ref_matched} should be the reference file #{ref_identifier}") { ref_matched == ref_identifier || ref_matched.to_i.to_s == ref_identifier }
assert("Match time in ref #{first_match.ref_start} should be close to query time #{first_match.query_start}") { (first_match.ref_start - first_match.query_start).abs < 2.0 }

assert("Reached end of tests!") { true}