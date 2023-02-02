#!/bin/env ruby

#small helper script to link to souce file in a way expected
#by the arduino IDE


if ARGV.size != 1
	STDERR.puts "A single folder name is expected as argument"
	exit(1)
	return
end

require 'fileutils'
folder = ARGV[0]

unless File.exist? folder
	FileUtils.mkdir_p folder
	system("touch #{folder}/#{folder}.ino")
end

source_files = %w(
hash-table.c
olaf_config.c
olaf_db_mem.c
olaf_ep_extractor.c
olaf_fp_extractor.c
olaf_fp_matcher.c
olaf_max_filter_naive.c
pffft.c
)

header_files = %w(
hash-table.h
olaf_config.h
olaf_db.h
olaf_ep_extractor.h
olaf_fp_extractor.h
olaf_fp_matcher.h
olaf_fp_ref_mem.h
olaf_max_filter.h
olaf_window.h
pffft.h
)

header_files.each do |header_file|
	system("ln -s ../../src/#{header_file} #{folder}")
end

source_files.each do |source_file|
	system("ln -s ../../src/#{source_file} #{File.join(folder,source_file)}pp")
end

