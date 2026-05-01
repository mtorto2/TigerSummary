# TigerDroppings Thread Summarizer

Minimal Python CLI prototype that:

1. accepts a TigerDroppings thread URL
2. fetches the first page
3. explicitly verifies the last page from pagination
4. crawls every page
5. extracts the thread posts
6. sends the dataset to the OpenAI API
7. prints a structured forum summary to the terminal
8. saves a Markdown copy in `Summaries/`

## Files

- `summarize_thread.py`
- `requirements.txt`
- `README.md`

## Requirements

- Python 3.9+
- An OpenAI API key in `OPENAI_API_KEY`

## Setup

Create and activate a virtual environment if you want one:

```bash
python3 -m venv .venv
source .venv/bin/activate
```

Install dependencies:

```bash
python3 -m pip install -r requirements.txt
```

Set your OpenAI API key in `.env`:

```bash
OPENAI_API_KEY="your_api_key_here"
```

You can also set it directly in your shell:

```bash
export OPENAI_API_KEY="your_api_key_here"
```

Optional: choose a different model in `.env` or your shell:

```bash
export OPENAI_MODEL="gpt-5.2"
```

## Usage

```bash
./run_tigersummarizer.sh "https://www.tigerdroppings.com/rant/o-t-lounge/example-thread/12345678/"
```

If that still fails with `ModuleNotFoundError`, make sure you installed packages into the same Python interpreter you are using to run the script:

```bash
python3 -m pip --version
python3 -m pip install -r requirements.txt
python3 summarize_thread.py "https://www.tigerdroppings.com/rant/o-t-lounge/example-thread/12345678/"
```

By default, each successful run also writes a Markdown file to `Summaries/`.

Useful options:

```bash
./run_tigersummarizer.sh "URL" --output Summaries/my-summary.md
./run_tigersummarizer.sh "URL" --no-save
./run_tigersummarizer.sh "URL" --notify-projecthub
```

ProjectHub notifications use the Telegram bot credentials from `/Users/matt/Dev/ProjectHub/bot/.env.telegram` or `.env.telegram.local`. You can also set `PROJECTHUB_NOTIFY=1` in `.env` to notify on every run.

## Menu Bar App

The repo includes an early native macOS wrapper that runs the Python summarizer in the background.

Build it:

```bash
swift build
```

Run it:

```bash
.build/debug/TigerSummarizerMenuBar
```

It adds a `TS` item to the macOS menu bar. Use `Summarize Clipboard URL` after copying a TigerDroppings thread link, or drag a URL onto the menu bar item. Results open in a local window and are also saved by the Python backend.

You should see progress messages like:

- `fetching first page...`
- `detected last page: X`
- `fetching page X of Y...`
- `total posts collected: N`
- `generating summary...`
- `Saved summary: ...`

## How it works

- The script normalizes the thread URL and fetches page 1.
- It inspects pagination and explicitly verifies the highest page number it can find.
- It fetches every page through that verified last page.
- It extracts posts using a practical text-pattern parser keyed off repeated `Posted by` / `Posted on` markers.
- It keeps jokes, sarcasm, trolling, and repeated bits as part of the dataset.
- It lightly trims oversized quote blocks to reduce duplicated context.
- If the thread is large, it summarizes in chunks and then combines those chunk summaries into one final structured summary.

## Output format

The model is prompted to return:

- `A. High-Level Summary`
- `B. Overall Sentiment`
- `C. Key Themes ("Users say...")`
- `D. Most Common Complaints`
- `E. Most Common Explanations / Theories`
- `F. Thread Vibe`
- `G. Notable / High-Signal Moments`
- `H. Signal vs Noise`
- `I. Key Takeaways`

## Known limitations

- This is a first-pass prototype, not a hardened scraper.
- TigerDroppings may change its HTML structure, which could break extraction.
- The parser currently relies on repeated text patterns from the rendered page, not a site-specific DOM contract.
- If TigerDroppings blocks requests or serves different markup, you may need to add cookies, retries, or switch to Playwright later.
- Quote trimming is intentionally conservative, but some duplicated context may still remain.
- Very large threads can still lose nuance during chunking because the model sees summarized chunks instead of the entire raw thread at once.
- The script prints a clear failure if post extraction appears incomplete or empty.
