#small script to update the gh-pages branch with the newest doxygen docs

require 'tmpdir'

html_files = "docs/api/html"

#call doxygen
system("doxygen")

Dir.mktmpdir do |d|
	
end



