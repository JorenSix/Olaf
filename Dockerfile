FROM node:16 as installer


RUN apt-get update
RUN apt-get -y install ffmpeg ruby make gcc

RUN mkdir /usr/src/app

WORKDIR /usr/src/app

COPY . .

RUN make && make install-su

RUN echo "Running!"


FROM installer

ENTRYPOINT ["tail", "-f", "/dev/null"]