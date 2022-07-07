FROM alpine:latest

RUN apk update
RUN apk add ruby ffmpeg gcc git make musl-dev

RUN mkdir -p /usr/src/olaf

WORKDIR /usr/src/olaf

COPY . .

RUN make && make install-su

RUN echo "Olaf installed!"

RUN mkdir -p /root/audio
WORKDIR /root/audio

RUN rm -rf /usr/src/olaf

RUN rm -rf /root/.olaf