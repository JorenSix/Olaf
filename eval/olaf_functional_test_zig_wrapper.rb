require_relative('olaf_result_line.rb')

#This script executes functional tests which should always work correctly
#They are checked during CI

class OlafStats
    attr_reader :number_of_songs, :total_duration

    def initialize
        res = `olaf stats 2>/dev/null`
        res =~ /.*.songs.+?:\t?(\d+).*/m
        @number_of_songs = $1.to_i
        res =~ /.*.otal.dura.+?:\t?(\d+.\d+).*/m
        @total_duration = $1.to_f

    end
end

#1, 1, 852601_43s-63s.mp3, 0 , 252, 86.01, 105.58, /Users/joren/Downloads/Olaf/eval/dataset/ref/852601.mp3, 4218917231, 43.08, 62.65


def assert(message, &block)
    unless block.call
        STDERR.puts "FAIL: #{message}"
        STDOUT.puts "FAIL: #{message}"
        exit -1
    else 
        STDOUT.puts "PASS: #{message}"
    end
end


assert("Database should be empty, before running tests run 'olaf clear'") { OlafStats.new.number_of_songs == 0 }

REF_TARGET_FOLDER = "dataset/ref"
#check dataset, if not available, download
ref_files = Dir.glob(File.join(REF_TARGET_FOLDER,"*mp3"))
if ref_files.length == 0
    STDERR.puts 'Test dataset not found. Downloading...'
    system("ruby eval/olaf_download_dataset.rb")
end
REF_FILES = Dir.glob(File.join(REF_TARGET_FOLDER,"*mp3")).sort

QUERY_TARGET_FOLDER = "dataset/queries"
QUERY_FILES = Dir.glob(File.join(QUERY_TARGET_FOLDER,"*mp3")).sort


assert("Test dataset check: If not found, download it first! call e.g. 'ruby eval/olaf_download_dataset.rb'") { REF_FILES.size > 0 && QUERY_FILES.size > 0 }

REF_FILES.each do |file|
    cmd = "olaf store '#{file}'"
    assert("Command : #{cmd}") { system(cmd) }
end

#Check the number of stored files
assert("Expected #{REF_FILES.size} stored, was #{OlafStats.new.number_of_songs}"){ OlafStats.new.number_of_songs == REF_FILES.size }

#Delete one file
cmd = "olaf delete '#{REF_FILES.last}'"
assert("Command : #{cmd}") { system(cmd) }
#Check the number of stored files
assert("Expected #{REF_FILES.size-1} stored, was #{OlafStats.new.number_of_songs}"){ (OlafStats.new.number_of_songs == (REF_FILES.size - 1)) }
#add it again
cmd = "olaf store '#{REF_FILES.last}'"
assert("Command : #{cmd}") { system(cmd) }

QUERY_FILES.each do |file|
    cmd = `olaf query '#{file}'`
    
    lines = cmd.split("\n").map{|l| OlafResultLine.new(l) }.delete_if{|l| !l.valid}
    
    #remove header
    lines.shift

    first_match = lines.first

    query_filename = File.basename(file,File.extname(file))
    query_filename =~/(\d+)_(\d+)s-(\d+)s/
    query_ref_id = $1.to_i
    query_ref_start = $2.to_i
    query_ref_stop = $3.to_i

    expect_match = REF_FILES.include? File.join(REF_TARGET_FOLDER,"#{query_ref_id}.mp3")

    assert("Expected match and match not found for #{query_filename}"){ expect_match != first_match.empty_match }

    if(expect_match)
      ref_id = File.basename(first_match.ref_path,File.extname(first_match.ref_path)).to_i
      assert("Found id #{ref_id} should be equal to expected id #{query_ref_id}") { query_ref_id == ref_id} 

      assert("Found time in ref #{first_match.ref_start}, q#{query_ref_start} should be close to expected time #{query_ref_start}") { (first_match.ref_start - query_ref_start).abs < 5.5}
      assert("Found time in ref #{first_match.ref_stop}, q#{query_ref_stop} should be close to expected time #{query_ref_stop}") { (first_match.ref_stop - query_ref_stop).abs < 5.5}
      actual_diff = (first_match.ref_start - first_match.query_start).abs
      assert("Expected diff #{query_ref_start} should be close to actual diff #{actual_diff}.") { (actual_diff - query_ref_start).abs < 0.1}
    end
end

#convert the dataset to raw
system("olaf to_raw #{REF_TARGET_FOLDER}")
system("mkdir -p dataset/raw/ref")
system("mv olaf_audio* dataset/raw/ref")
REF_FILES_RAW = Dir.glob(File.join("dataset/raw/ref","*raw")).sort
assert("Conversion of audio to raw"){REF_FILES_RAW.size == REF_FILES.size}

system("olaf to_raw #{QUERY_TARGET_FOLDER}")
system("mkdir -p dataset/raw/queries")
system("mv olaf_audio* dataset/raw/queries")
QUERY_FILES_RAW = Dir.glob(File.join("dataset/raw/queries","*raw")).sort
assert("Conversion of audio to raw"){QUERY_FILES_RAW.size == QUERY_FILES.size}


assert("Reached end of tests!") { true}

exit 0