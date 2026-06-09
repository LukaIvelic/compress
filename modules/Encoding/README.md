# Encoding

`ffmpeg` encoding logic.

This module builds the pass arguments, reads `ffmpeg -progress` output, and updates the shared progress bar.

CPU mode uses two-pass `libx264`. NVIDIA mode uses `h264_nvenc` with VBR, full-resolution multipass, and the same outer size-check loop.

NVENC mode accepts a wider "close enough" size window because hardware VBR can overshoot bitrate targets and repeated full GPU retries are expensive.

`ffmpeg` stderr is captured separately so recoverable encoder warnings do not break the progress display.
