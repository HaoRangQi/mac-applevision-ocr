> 🇨🇳 [中文](README.md) · 🇺🇸 **English**

# applevision-ocr

Local OCR that turns scanned PDFs and images into readable text, with Chinese paragraphs, tables, and footnotes reconstructed faithfully.

Built on macOS's built-in **Vision** framework — everything runs on your machine. No network, no uploads, no API key.

![Screenshot → Text](docs/showcase.png)

*The image above is a real result: the original screenshot on the left, the raw text output of `applevision-ocr` on the right, produced by `applevision-ocr screenshot.png --no-vote` with no manual editing.*

## Why this one

- **Fully local**: calls system Vision, makes no network requests, so sensitive documents never leave your Mac.
- **Reads scanned files**: PDFs without a text layer that copy-paste as blanks can only be recovered through OCR.
- **Chinese accuracy via multi-pass voting**: the same page is recognized at three resolutions and voted character by character to cancel out single-character misreads.
- **Reconstructs layout**: splits paragraphs by indentation, continues across pages, turns tables into grids, moves footnotes to the end, and replaces figure captions with placeholders.
- **Same engine, two front-ends**: the GUI `AppleVisionOCR.app` and the CLI `applevision-ocr` share one pipeline.

## Install

Requires macOS 13+, Xcode Command Line Tools (`xcode-select --install`), and python3 (the system one is fine).

```bash
git clone <repo-url> applevision-ocr
cd applevision-ocr
make install          # compile engine + install command to ~/.local/bin
make install-app      # package AppleVisionOCR.app to ~/Applications
```

`make install` does three things: compiles the Swift engine to `bin/ocrvision`, installs the Python wrapper under `~/.local/share/applevision-ocr`, and drops an `applevision-ocr` launcher into `~/.local/bin`.

## Usage

### GUI

```bash
open ~/Applications/AppleVisionOCR.app
```

![Interface](docs/screenshot.png)

Drop in a PDF or image → pick the page range and output shape → start recognition → copy or save.

Results are **written straight to a file by default**. The path is editable and defaults to the same name as the source file, with a `.txt` extension. Large texts are never rendered on screen, so the UI stays responsive: after a run you get the first 2,000 characters as a preview plus buttons to open the file or reveal it in Finder. Switch to 界面显示 if you would rather watch small results inline.

`Cmd+O` opens a file, `Cmd+R` starts; double-clicking a PDF in Finder also opens it in this app.

### Command line

```bash
applevision-ocr book.pdf                      # whole book → book.txt
applevision-ocr book.pdf -p 26-142 -o out.txt # specific page range
applevision-ocr book.pdf -p 1,5,20-30         # several disjoint segments
applevision-ocr book.pdf -p -10               # the last 10 pages
applevision-ocr scan.png                      # image → terminal
applevision-ocr a.pdf b.pdf -o out/           # batch, output to a directory
applevision-ocr paper.pdf --lang en-US        # English-only document
```

Common flags:

| Flag | Description |
| --- | --- |
| `-p, --pages 26-40` | Page range (PDF only): multi-segment `1,5,20-30`, or `-10` for the last 10 pages |
| `-o, --out` | Output file; treated as a directory when multiple inputs are given |
| `--mode layout\|text\|json` | Reconstruct paragraphs (default) / line-by-line / coordinate JSON |
| `--scales 3.5,4.5,5.6` | Render scales for voting; a single value disables voting |
| `--no-vote` | Disable multi-pass voting, about 3× faster |
| `--rot -90` | Rotate the whole page before recognition, for landscape tables |
| `--wrap 76` | Soft-wrap by character count (0 = off): breaks at the next sentence punctuation after ~76 chars |
| `--no-tables` | Don't reconstruct tables |
| `--furniture off` | Don't auto-strip headers/footers (use for screenshot-style documents) |
| `--notes end\|drop` | Footnotes to end of text / dropped |
| `--lang zh-Hans,en-US` | Recognition languages |
| `-q, --quiet` | Silence progress output (one `page N` line per page by default) |

## How it works

```
PDF/image ──► Engine (Swift + Vision) ──► per-line JSON (with coordinates)
                                       │
                    3 resolutions, each run once ─┴─► per-character vote
                                       │
                                  layout reconstruction ──► text
```

1. **Render & recognize**: `src/engine/ocrvision.swift` renders each page to a bitmap with PDFKit and feeds it to `VNRecognizeTextRequest`, emitting text lines with normalized coordinates.
2. **Multi-pass voting**: a single pass reliably reads「的」as「钓/前/哟」on Chinese text, but the errors shift with resolution. After three passes most single-character errors vanish;「的」gets extra weight because it is far more often dropped than invented.
3. **Layout reconstruction**: cross-page headers/footers are dropped by frequency after normalizing numbers; paragraphs are detected by first-line indentation; lines with a smaller font are treated as footnotes; pages dense with short lines are clustered into tables by coordinates; figure captions become placeholder notes.
4. **Error correction**: Vision's fixed biases on Chinese print (`钓→的`, `AT→AI`, `欢盟→欧盟`, etc.) are collected as rules in `src/applevision_ocr/fixes.py`.

See [docs/architecture.md](docs/architecture.md) for details.

## Performance

| Scenario | Time |
| --- | --- |
| Single image | ≈ 0.9 s |
| Book page (3-pass vote) | ≈ 2.4 s/page |
| 258-page scanned book | ≈ 12 min |

`--no-vote` brings a book page down to about 0.8 s/page, at the cost of more single-character errors.

## Known limitations

- Low accuracy on handwriting and decorative fonts.
- Complex tables after a whole-page rotation: `--rot` recovers the content but columns may misalign.
- Charts and diagrams only yield a caption placeholder; the graphics themselves are not reconstructed.
- Vertical classical texts need separate handling; horizontal layout is assumed by default.

## Development

```bash
make test     # unit tests (pure logic, no macOS API needed)
make engine   # compile only the engine
make clean    # clean build artifacts
```

Directory layout:

```
src/engine/           Swift OCR engine
src/applevision_ocr/  Python package: voting, layout, fixes, CLI
app/                 SwiftUI interface
scripts/             build, install, icon
tests/               unit tests
docs/                architecture notes and screenshots
```

## License

MIT. See [LICENSE](LICENSE).

**Apple** and **Vision** are trademarks of Apple Inc., used here only to describe the underlying technology. This project is not affiliated with or endorsed by Apple Inc. If you distribute on the App Store or in a commercial setting, rename the product to your own.
