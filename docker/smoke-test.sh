#!/usr/bin/env bash
# Usage: bash docker/smoke-test.sh IMAGE PLATFORM MUSIC_DIRECTORY
# MUSIC_DIRECTORY must contain the project's 11266.mp3 reference fixture.
set -euo pipefail
image=$1
platform=$2
music=$(cd "$3" && pwd)
volume=$(docker volume create)
trap 'docker volume rm "$volume" >/dev/null' EXIT
run=(docker run --rm --platform "$platform" -v "$volume:/data" -v "$music:/music:ro")
"${run[@]}" "$image" help >/dev/null
"${run[@]}" --entrypoint ffmpeg "$image" -version | grep 'ffmpeg version 8.1.2'
"${run[@]}" --entrypoint ffprobe "$image" -v error -show_entries format=duration /music/11266.mp3
# Match in a NEW container to verify persistence and non-root volume permissions.
"${run[@]}" "$image" store /music/11266.mp3
"${run[@]}" "$image" stats
result=$("${run[@]}" "$image" query /music/11266.mp3)
printf '%s\n' "$result"
printf '%s\n' "$result" | grep '/music/11266.mp3.*11266.mp3'
# Exercise the exact MP3 encoder used for web UI clips.
"${run[@]}" --entrypoint ffmpeg "$image" -v error -i /music/11266.mp3 -t 1 -vn -ac 2 -ar 44100 -c:a libmp3lame -b:a 192k -f mp3 pipe:1 >/dev/null
# A distroless runtime must have neither shell nor package manager.
if "${run[@]}" --entrypoint /bin/sh "$image" -c true 2>/dev/null; then
  echo 'Unexpected shell in runtime' >&2
  exit 1
fi
docker image inspect "$image" --format 'Size: {{.Size}} bytes; user: {{.Config.User}}'
