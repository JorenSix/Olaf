#Use Alpine linux as a base, a small distro
#The version and architecture is not that relevant
#The dependencies should be present
FROM alpine:latest as builder

#update the package index
RUN apk update

RUN apk add zig 

RUN mkdir -p /usr/src/olaf
WORKDIR /usr/src/olaf

RUN zig build-exe src/olaf.zig -O ReleaseSafe --library c --library m --out-dir .

COPY . .


FROM alpine:latest as runner

RUN mkdir -p /usr/src/olaf
WORKDIR /usr/src/olaf
COPY --from=builder /usr/src/olaf /usr/src/olaf

#Install dependencies:
# - ffmpeg to convert audio
# The version of each dependency is not that critical
# The interfaces used should be rather stable over time
RUN apk add ffmpeg 

#Create a temporary directory for the source files
#and switch to it


#copy the source files


#compile and install Olaf
RUN make && make install-su && make clean
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
