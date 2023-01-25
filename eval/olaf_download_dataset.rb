require 'open-uri'
require 'fileutils'

REF_URL = "https://0110.be/releases/Panako/Panako-test-dataset/reference/"
REF_FILES = %w(1051039.mp3 1071559.mp3 1075784.mp3 11266.mp3 147199.mp3 173050.mp3 189211.mp3 297888.mp3 612409.mp3 852601.mp3)
REF_TARGET_FOLDER = "dataset/ref"

QUERY_URL = "https://0110.be/releases/Panako/Panako-test-dataset/queries/"
QUERY_FILES = %w(1024035_55s-75s.mp3 1051039_34s-54s.mp3 1071559_60s-80s.mp3 1075784_78s-98s.mp3 11266_69s-89s.mp3 132755_137s-157s.mp3 147199_115s-135s.mp3 173050_86s-106s.mp3 189211_60s-80s.mp3 295781_88s-108s.mp3 297888_45s-65s.mp3 361430_180s-200s.mp3 371009_187s-207s.mp3 378501_59s-79s.mp3 384991_294s-314s.mp3 432279_81s-101s.mp3 43383_224s-244s.mp3 478466_24s-44s.mp3 602848_242s-262s.mp3 604705_154s-174s.mp3 612409_73s-93s.mp3 824093_182s-202s.mp3 84302_232s-252s.mp3 852601_43s-63s.mp3 96644_84s-104s.mp3)
QUERY_TARGET_FOLDER = "dataset/queries"

def download(url,target)
    download = URI.open(url)
    IO.copy_stream(download, target)
end

def download_files(url, target_folder, files)
    files.each do |file|
      target = File.join(target_folder, file)
      FileUtils.mkdir_p target_folder unless File.exist? target_folder
      if File.exist? target
          puts "Found cached file #{target}"
      else
          puts "Downloading #{target}"
          download(url + file, target) 
          puts "Downloaded #{target}"
      end
    end
end

  def check_files(folder, glob, min_size_in_bytes)
    Dir.glob(File.join(folder,glob)).each do |file|
        unless File.size(file) > min_size_in_bytes
            STDERR.puts "#{file} too small: #{File.size(file)}"
            return false
        end
    end
    return true
end
  
  
download_files(REF_URL, REF_TARGET_FOLDER, REF_FILES)
exit -1 unless check_files(REF_TARGET_FOLDER,"*.mp3",100*1024)

download_files(QUERY_URL, QUERY_TARGET_FOLDER, QUERY_FILES)
exit -1 unless check_files(QUERY_TARGET_FOLDER,"*.mp3",100*1024)

exit 0