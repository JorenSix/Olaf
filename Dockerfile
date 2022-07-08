#Use Alpine linux as a base, a small distro
#The version and architecture is not that relevant
#The dependencies should be present
FROM alpine:latest

#update the package index
RUN apk update

#Install dependencies:
# - ruby to run the Olaf runner script
# - ffmpeg to convert audio
# - make, gcc and musl-dev to compile Olaf
#
# The version of each dependency is not that critical
# The interfaces used should be rather stable over time
RUN apk add ruby ffmpeg gcc make musl-dev

#Create a temporary directory for the source files
#and switch to it
RUN mkdir -p /usr/src/olaf
WORKDIR /usr/src/olaf

#copy the source files
COPY . .

#compile and install Olaf
RUN make && make install-su
RUN echo "Olaf compiled and installed!"

#Make and switch to the audio directory
# This directory will be mounted and used as passthrough 
# from host to container
RUN mkdir -p /root/audio
WORKDIR /root/audio

#We do not need the temporary source files any more
RUN rm -rf /usr/src/olaf

#The database folder will be mounted from the host so that
# the database + configuration persists over time
# the folder can be removed
RUN rm -rf /root/.olaf
