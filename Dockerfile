FROM ubuntu:latest


RUN apt-get update
RUN apt-get -y install ffmpeg ruby make gcc

RUN mkdir /usr/src/app

WORKDIR /usr/src/app

COPY . .

RUN make && make install-su

RUN echo "Running!"
ENTRYPOINT ["tail", "-f", "/dev/null"]
