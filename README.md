# compress

Small Windows wrapper around `ffmpeg` that creates an MP4 below 8 MB.

Usage:

```bat
compress "C:\path\video.mp4"
compress -d "C:\path\folder"
```

Add `C:\dev\compress` to PATH. Output is written next to the source as `<name>-compressed.mp4`.

Directory mode compresses every `.mp4` in the folder non-recursively and skips files already named `*-compressed.mp4`.

The command shows a compact progress bar instead of raw `ffmpeg` output.

Implementation modules live in `modules/*`; each module directory includes its own README.
