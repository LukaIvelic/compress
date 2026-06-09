# Encoding

Two-pass `ffmpeg` encoding logic.

This module builds the pass arguments, reads `ffmpeg -progress` output, and updates the shared progress bar.

`ffmpeg` stderr is captured separately so recoverable encoder warnings do not break the progress display.
