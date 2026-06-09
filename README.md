# compress

Small Windows wrapper around `ffmpeg` that creates an MP4 below 8 MB.

Usage:

```bat
compress "C:\path\video.mp4"
compress -n "C:\path\video.mp4"
compress -d "C:\path\folder"
compress -n -d "C:\path\folder"
```

Add `C:\dev\compress` to PATH. Output is written next to the source as `<name>-compressed.mp4`.

The 8 MB target is enforced for up to five attempts. If the file still cannot fit, the fifth attempt is kept as the best-effort compressed output.

Directory mode compresses every `.mp4` in the folder non-recursively and skips files already named `*-compressed.mp4`.

Use `-n` to encode with NVIDIA NVENC (`h264_nvenc`) instead of CPU `libx264`.

The command shows a compact progress bar instead of raw `ffmpeg` output.

Implementation modules live in `modules/*`; each module directory includes its own README.
