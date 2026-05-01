#!/usr/bin/env python3
"""
Quick-and-dirty TigerDroppings thread summarizer.

Workflow:
1. Accept a TigerDroppings thread URL
2. Fetch the first page
3. Explicitly verify the final page from pagination
4. Crawl every page
5. Extract posts into a lightweight dataset
6. Send the dataset to the OpenAI API
7. Print an Amazon-style structured forum summary
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import textwrap
from datetime import datetime
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, List, Optional
from urllib.parse import urljoin, urlparse

import requests
from bs4 import BeautifulSoup
from openai import OpenAI


PROJECT_DIR = Path(__file__).resolve().parent
ENV_FILE = PROJECT_DIR / ".env"
DEFAULT_OUTPUT_DIR = PROJECT_DIR / "Summaries"
DEFAULT_PROJECTHUB_BOT_DIR = PROJECT_DIR.parent / "ProjectHub" / "bot"
REQUEST_TIMEOUT = 30
USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/124.0.0.0 Safari/537.36"
)
CHUNK_CHAR_LIMIT = 12000


def load_env_file(path: Path = ENV_FILE) -> None:
    if not path.exists():
        return

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue

        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key and key not in os.environ:
            os.environ[key] = value


@dataclass
class Post:
    index: int
    page: int
    post_id: Optional[str]
    username: Optional[str]
    timestamp: Optional[str]
    reply_to: Optional[str]
    upvotes: Optional[int]
    downvotes: Optional[int]
    reply_count: Optional[int]
    text: str

    @property
    def vote_score(self) -> Optional[int]:
        if self.upvotes is None and self.downvotes is None:
            return None
        return (self.upvotes or 0) - (self.downvotes or 0)


@dataclass
class ThreadData:
    title: str
    first_page_url: str
    verified_last_page: int
    posts: List[Post]


def parse_args() -> argparse.Namespace:
    default_model = os.getenv("OPENAI_MODEL", "gpt-5.2")
    parser = argparse.ArgumentParser(
        description="Summarize a TigerDroppings thread with the OpenAI API."
    )
    parser.add_argument("url", help="TigerDroppings thread URL")
    parser.add_argument(
        "--model",
        default=default_model,
        help=f"OpenAI model to use (default: {default_model})",
    )
    parser.add_argument(
        "--output",
        type=Path,
        help="Write the summary to this Markdown file.",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=DEFAULT_OUTPUT_DIR,
        help=f"Directory for auto-saved summaries (default: {DEFAULT_OUTPUT_DIR})",
    )
    parser.add_argument(
        "--no-save",
        action="store_true",
        help="Print the summary without saving a Markdown copy.",
    )
    parser.add_argument(
        "--notify-projecthub",
        action="store_true",
        help="Send start/finish/failure messages through the ProjectHub Telegram bot.",
    )
    return parser.parse_args()


def build_session() -> requests.Session:
    session = requests.Session()
    session.headers.update({"User-Agent": USER_AGENT})
    return session


def normalize_thread_url(url: str) -> str:
    parsed = urlparse(url.strip())
    if parsed.scheme not in {"http", "https"}:
        raise ValueError("URL must start with http:// or https://")
    if "tigerdroppings.com" not in parsed.netloc.lower():
        raise ValueError("URL must point to tigerdroppings.com")

    path = re.sub(r"/page-\d+/?$", "/", parsed.path)
    path = re.sub(r"/+$", "/", path)
    return f"{parsed.scheme}://{parsed.netloc}{path}"


def make_page_url(base_url: str, page_number: int) -> str:
    if page_number <= 1:
        return base_url
    return f"{base_url}page-{page_number}/"


def fetch_page(session: requests.Session, url: str) -> str:
    response = session.get(url, timeout=REQUEST_TIMEOUT)
    response.raise_for_status()
    return response.text


def extract_title(soup: BeautifulSoup) -> str:
    title_tag = soup.find("title")
    if not title_tag or not title_tag.get_text(strip=True):
        return "Untitled TigerDroppings thread"

    raw_title = title_tag.get_text(" ", strip=True)
    title = raw_title.split("|")[0].strip()
    title = re.sub(r"^\s*re:\s*", "", title, flags=re.IGNORECASE)
    return title or "Untitled TigerDroppings thread"


def canonical_thread_path(url: str) -> str:
    parsed = urlparse(normalize_thread_url(url))
    return parsed.path


def detect_last_page(soup: BeautifulSoup, page_text: str, thread_url: str) -> int:
    text_matches = [
        int(match.group(1))
        for match in re.finditer(r"Page\s+\d+\s+of\s+(\d+)", page_text, flags=re.IGNORECASE)
    ]
    if text_matches:
        return max(text_matches)

    thread_path = canonical_thread_path(thread_url)
    page_candidates = {1}

    for link in soup.find_all("a", href=True):
        resolved = urljoin(thread_url, link["href"])
        parsed = urlparse(resolved)
        normalized_path = re.sub(r"/page-\d+/?$", "/", parsed.path)
        normalized_path = re.sub(r"/+$", "/", normalized_path)
        if normalized_path != thread_path:
            continue

        page_match = re.search(r"/page-(\d+)/?$", parsed.path)
        if page_match:
            page_candidates.add(int(page_match.group(1)))

    return max(page_candidates)


def reduce_quote_duplication(text: str) -> str:
    lines = [line.rstrip() for line in text.splitlines()]
    cleaned: List[str] = []
    quote_buffer: List[str] = []
    quote_notice_added = False

    def flush_quotes() -> None:
        nonlocal quote_buffer, quote_notice_added
        if not quote_buffer:
            return
        preview = quote_buffer[:4]
        cleaned.extend(preview)
        if len(quote_buffer) > 4 and not quote_notice_added:
            cleaned.append("[quoted text trimmed]")
            quote_notice_added = True
        quote_buffer = []

    for line in lines:
        if line.strip().startswith(">"):
            quote_buffer.append(line)
            continue
        flush_quotes()
        cleaned.append(line)

    flush_quotes()

    compact = []
    last_blank = False
    for line in cleaned:
        blank = not line.strip()
        if blank and last_blank:
            continue
        compact.append(line)
        last_blank = blank
    return "\n".join(compact).strip()


def normalize_line(line: str) -> str:
    line = line.replace("\xa0", " ")
    line = re.sub(r"\s+", " ", line)
    return line.strip()


def is_skippable_line(line: str) -> bool:
    stripped = line.strip()
    if not stripped:
        return False

    fixed = {
        "Back to top",
        "Report Post",
        "Advertisement",
        "Thank you for supporting our sponsors",
        "TD Sponsor",
        "TD Fan",
        "USA",
    }
    if stripped in fixed:
        return True

    if stripped.startswith("Reply"):
        return True
    if stripped.startswith("Page "):
        return True
    if re.fullmatch(r"\d+", stripped):
        return False
    if re.fullmatch(r"Member since .+", stripped):
        return True
    if re.fullmatch(r"\d+\s+posts", stripped):
        return True
    return False


def parse_reply_target(header_line: str) -> Optional[str]:
    match = re.search(r"\bto\s+(.+)$", header_line)
    if match:
        return match.group(1).strip() or None
    return None


def starts_post_marker(line: str) -> bool:
    return bool(re.match(r"^Posted by\b", line, flags=re.IGNORECASE))


def starts_time_marker(line: str) -> bool:
    return bool(re.match(r"^Posted on\b", line, flags=re.IGNORECASE))


def parse_int_text(value: Optional[str]) -> Optional[int]:
    if value is None:
        return None
    match = re.search(r"-?\d+", value.replace(",", ""))
    if not match:
        return None
    return int(match.group(0))


def parse_post_id_from_text_id(value: Optional[str]) -> Optional[str]:
    if not value:
        return None
    match = re.search(r"ptext_(\d+)", value)
    return match.group(1) if match else None


def extract_reply_count(post_row: BeautifulSoup) -> Optional[int]:
    for link in post_row.select("a.rep-button"):
        href = link.get("href", "")
        if "s=4" not in href:
            continue
        text = link.get_text(" ", strip=True)
        count = parse_int_text(text)
        if count is not None:
            return count
    return None


def parse_dom_posts_from_html(html: str, page_number: int, starting_index: int) -> List[Post]:
    soup = BeautifulSoup(html, "html.parser")
    posts: List[Post] = []
    post_index = starting_index

    for body_node in soup.select(".pText[id^='ptext_']"):
        post_row = body_node.find_parent(class_=re.compile(r"\bmaincont1\b"))
        if not post_row:
            continue

        post_id = parse_post_id_from_text_id(body_node.get("id"))
        author_link = post_row.select_one(".author a.RegUser")
        username = author_link.get_text(" ", strip=True) if author_link else None

        time_node = post_row.select_one(".time")
        timestamp = normalize_line(time_node.get_text(" ", strip=True)) if time_node else None

        reply_link = post_row.select_one(".time a.PostInfo")
        reply_to = reply_link.get_text(" ", strip=True) if reply_link else None

        upvotes = None
        downvotes = None
        if post_id:
            up_node = post_row.select_one(f"#T_Up_p{post_id}")
            down_node = post_row.select_one(f"#T_Down_p{post_id}")
            upvotes = parse_int_text(up_node.get_text(" ", strip=True) if up_node else None)
            downvotes = parse_int_text(down_node.get_text(" ", strip=True) if down_node else None)

        reply_count = extract_reply_count(post_row)
        body = reduce_quote_duplication(body_node.get_text("\n", strip=True))
        if not body:
            continue

        posts.append(
            Post(
                index=post_index,
                page=page_number,
                post_id=post_id,
                username=username,
                timestamp=timestamp,
                reply_to=reply_to,
                upvotes=upvotes,
                downvotes=downvotes,
                reply_count=reply_count,
                text=body,
            )
        )
        post_index += 1

    return posts


def parse_posts_from_html(html: str, page_number: int, starting_index: int) -> List[Post]:
    dom_posts = parse_dom_posts_from_html(html, page_number, starting_index)
    if dom_posts:
        return dom_posts

    soup = BeautifulSoup(html, "html.parser")
    lines = [normalize_line(line) for line in soup.get_text("\n", strip=True).splitlines()]
    lines = [line for line in lines if line]

    posts: List[Post] = []
    i = 0
    post_index = starting_index

    while i < len(lines):
        if not starts_post_marker(lines[i]):
            i += 1
            continue

        username = re.sub(r"^Posted by\s+", "", lines[i], flags=re.IGNORECASE).strip() or None
        timestamp = None
        reply_to = None
        body_lines: List[str] = []
        i += 1

        while i < len(lines):
            line = lines[i]

            if starts_post_marker(line):
                break

            if starts_time_marker(line):
                timestamp = line
                reply_to = parse_reply_target(line)
                i += 1
                break

            i += 1

        while i < len(lines):
            line = lines[i]
            if starts_post_marker(line):
                break
            if is_skippable_line(line):
                i += 1
                continue
            body_lines.append(line)
            i += 1

        body = reduce_quote_duplication("\n".join(body_lines))
        if body:
            posts.append(
                Post(
                    index=post_index,
                    page=page_number,
                    post_id=None,
                    username=username,
                    timestamp=timestamp,
                    reply_to=reply_to,
                    upvotes=None,
                    downvotes=None,
                    reply_count=None,
                    text=body,
                )
            )
            post_index += 1

    return posts


def crawl_thread(session: requests.Session, thread_url: str) -> ThreadData:
    print("fetching first page...", file=sys.stderr)
    first_html = fetch_page(session, thread_url)
    first_soup = BeautifulSoup(first_html, "html.parser")
    first_text = first_soup.get_text("\n", strip=True)

    title = extract_title(first_soup)
    last_page = detect_last_page(first_soup, first_text, thread_url)
    print(f"detected last page: {last_page}", file=sys.stderr)

    all_posts: List[Post] = []
    for page_number in range(1, last_page + 1):
        page_url = make_page_url(thread_url, page_number)
        print(f"fetching page {page_number} of {last_page}...", file=sys.stderr)
        html = first_html if page_number == 1 else fetch_page(session, page_url)
        page_posts = parse_posts_from_html(html, page_number, len(all_posts) + 1)
        all_posts.extend(page_posts)

    print(f"total posts collected: {len(all_posts)}", file=sys.stderr)
    return ThreadData(
        title=title,
        first_page_url=thread_url,
        verified_last_page=last_page,
        posts=all_posts,
    )


def slugify_filename(value: str, fallback: str = "thread-summary") -> str:
    slug = re.sub(r"[^a-zA-Z0-9]+", "-", value.lower()).strip("-")
    slug = re.sub(r"-{2,}", "-", slug)
    return (slug or fallback)[:80]


def build_summary_document(thread: ThreadData, summary: str, model: str) -> str:
    generated_at = datetime.now().astimezone().isoformat(timespec="seconds")
    return textwrap.dedent(
        f"""
        # {thread.title}

        Source: {thread.first_page_url}
        Generated: {generated_at}
        Model: {model}
        Pages: {thread.verified_last_page}
        Extracted posts: {len(thread.posts)}

        ---

        {summary.strip()}
        """
    ).strip() + "\n"


def default_summary_path(thread: ThreadData, output_dir: Path) -> Path:
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    slug = slugify_filename(thread.title)
    return output_dir / f"{timestamp}-{slug}.md"


def save_summary(thread: ThreadData, summary: str, model: str, output_path: Path) -> Path:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(build_summary_document(thread, summary, model), encoding="utf-8")
    return output_path


def load_projecthub_env(bot_dir: Path) -> None:
    for path in [bot_dir / ".env.telegram", bot_dir / ".env.telegram.local"]:
        load_env_file(path)


def projecthub_notifications_enabled(args: argparse.Namespace) -> bool:
    env_value = os.getenv("PROJECTHUB_NOTIFY", "").strip().lower()
    return args.notify_projecthub or env_value in {"1", "true", "yes", "on"}


def send_projecthub_message(text: str) -> None:
    bot_dir = Path(os.getenv("PROJECTHUB_BOT_DIR", str(DEFAULT_PROJECTHUB_BOT_DIR))).expanduser()
    load_projecthub_env(bot_dir)

    bot_token = os.getenv("TELEGRAM_BOT_TOKEN")
    chat_id = os.getenv("TELEGRAM_REPLY_CHAT_ID")
    if not bot_token or not chat_id:
        print(
            "ProjectHub notification skipped: TELEGRAM_BOT_TOKEN or TELEGRAM_REPLY_CHAT_ID is missing.",
            file=sys.stderr,
        )
        return

    try:
        response = requests.post(
            f"https://api.telegram.org/bot{bot_token}/sendMessage",
            data={
                "chat_id": chat_id,
                "text": text[:4000],
                "disable_web_page_preview": "true",
            },
            timeout=15,
        )
        response.raise_for_status()
    except requests.RequestException as exc:
        print(f"ProjectHub notification failed: {exc}", file=sys.stderr)


def print_app_event(event: str, **payload: object) -> None:
    print(f"APP_EVENT {json.dumps({'event': event, **payload})}", file=sys.stderr)


def chunk_posts(posts: Iterable[Post], max_chars: int = CHUNK_CHAR_LIMIT) -> List[str]:
    chunks: List[str] = []
    current_parts: List[str] = []
    current_length = 0

    for post in posts:
        block = format_post(post)
        block_length = len(block)

        if current_parts and current_length + block_length > max_chars:
            chunks.append("\n\n".join(current_parts))
            current_parts = [block]
            current_length = block_length
        else:
            current_parts.append(block)
            current_length += block_length

    if current_parts:
        chunks.append("\n\n".join(current_parts))

    return chunks


def format_post(post: Post) -> str:
    header_parts = [
        f"post={post.index}",
        f"page={post.page}",
        f"user={post.username or 'unknown'}",
    ]
    if post.post_id:
        header_parts.append(f"post_id={post.post_id}")
    if post.timestamp:
        header_parts.append(f"time={post.timestamp}")
    if post.reply_to:
        header_parts.append(f"reply_to={post.reply_to}")
    if post.upvotes is not None:
        header_parts.append(f"upvotes={post.upvotes}")
    if post.downvotes is not None:
        header_parts.append(f"downvotes={post.downvotes}")
    if post.vote_score is not None:
        header_parts.append(f"vote_score={post.vote_score}")
    if post.reply_count is not None:
        header_parts.append(f"reply_count={post.reply_count}")

    header = " | ".join(header_parts)
    return f"[{header}]\n{post.text}"


def format_engagement_post(post: Post) -> str:
    stats = [
        f"post={post.index}",
        f"page={post.page}",
        f"user={post.username or 'unknown'}",
    ]
    if post.post_id:
        stats.append(f"post_id={post.post_id}")
    if post.upvotes is not None:
        stats.append(f"upvotes={post.upvotes}")
    if post.downvotes is not None:
        stats.append(f"downvotes={post.downvotes}")
    if post.vote_score is not None:
        stats.append(f"vote_score={post.vote_score}")
    if post.reply_count is not None:
        stats.append(f"reply_count={post.reply_count}")

    excerpt = normalize_line(post.text.replace("\n", " "))
    if len(excerpt) > 260:
        excerpt = excerpt[:257].rstrip() + "..."
    return f"- {' | '.join(stats)}\n  excerpt: {excerpt}"


def build_engagement_snapshot(posts: List[Post], limit: int = 8) -> str:
    def with_votes(post: Post) -> bool:
        return post.upvotes is not None or post.downvotes is not None or post.reply_count is not None

    voted_posts = [post for post in posts if with_votes(post)]
    if not voted_posts:
        return "No vote or reply-count metadata was extracted for this thread."

    top_upvotes = sorted(voted_posts, key=lambda post: post.upvotes or 0, reverse=True)[:limit]
    top_score = sorted(voted_posts, key=lambda post: post.vote_score if post.vote_score is not None else -10**9, reverse=True)[:limit]
    top_replies = sorted(voted_posts, key=lambda post: post.reply_count or 0, reverse=True)[:limit]
    most_downvoted = sorted(voted_posts, key=lambda post: post.downvotes or 0, reverse=True)[:limit]

    sections = [
        ("Most upvoted", top_upvotes),
        ("Highest vote score", top_score),
        ("Most replied-to", top_replies),
        ("Most downvoted / controversial", most_downvoted),
    ]

    parts = []
    for title, section_posts in sections:
        meaningful = [
            post
            for post in section_posts
            if (post.upvotes or 0) > 0 or (post.downvotes or 0) > 0 or (post.reply_count or 0) > 0
        ]
        if not meaningful:
            continue
        parts.append(title + ":\n" + "\n".join(format_engagement_post(post) for post in meaningful[:limit]))

    return "\n\n".join(parts) if parts else "Vote and reply metadata was extracted, but all counts were zero."


def build_chunk_prompt(thread: ThreadData, chunk_text: str, chunk_number: int, chunk_total: int) -> str:
    return textwrap.dedent(
        f"""
        You are summarizing one chunk from a TigerDroppings forum thread.

        Thread title: {thread.title}
        Source URL: {thread.first_page_url}
        Verified total pages: {thread.verified_last_page}
        Chunk: {chunk_number} of {chunk_total}

        Important rules:
        - Treat jokes, trolling, sarcasm, memes, and repeated running bits as meaningful signal.
        - Do not sanitize the tone into corporate blandness.
        - Do not summarize page by page.
        - Preserve post numbers, users, pages, post IDs, upvotes, downvotes, vote score, and reply counts for posts that perform well or are high-signal.
        - Treat high upvotes, high vote score, high reply count, and unusually high downvotes as useful engagement signals.
        - Note uncertainty if the chunk is noisy or context-dependent.
        - Keep it concise because this is an intermediate chunk summary.

        Return these sections:
        1. Core discussion
        2. Sentiment and tone
        3. Repeated jokes / memes / trolling
        4. Complaints
        5. Explanations / theories
        6. High-signal / high-engagement moments, with post numbers and vote/reply stats when available
        7. Chunk limitations

        Thread chunk:
        {chunk_text}
        """
    ).strip()


def build_final_prompt(thread: ThreadData, chunk_summaries: List[str]) -> str:
    joined_chunks = "\n\n".join(
        f"Chunk summary {index}:\n{summary}"
        for index, summary in enumerate(chunk_summaries, start=1)
    )
    return textwrap.dedent(
        f"""
        Create an Amazon-style summary of this full TigerDroppings thread.

        Thread title: {thread.title}
        Source URL: {thread.first_page_url}
        Verified total pages: {thread.verified_last_page}
        Total extracted posts: {len(thread.posts)}

        Instructions:
        - Treat the thread as a full dataset, not isolated comments.
        - Preserve the cultural tone: humor, trolling, sarcasm, repeated jokes, and dunking matter.
        - Be honest about uncertainty or parsing gaps.
        - Do not produce a page-by-page recap.
        - Keep the output succinct: prioritize signal, avoid repeating the same point across sections.
        - Highlight posts by post number/user/page/post ID when they have high upvotes, high vote score, high reply count, unusually high downvotes, or strong substance/humor.
        - Use real vote/reply stats when present. If stats are missing, say "inferred highlight" rather than implying real vote data.
        - Keep most bullets to one sentence.

        Output exactly these sections:
        A. High-Level Summary
        B. Overall Sentiment
           - Positive: X% | Negative: Y% | Neutral: Z%
           - One-line description of tone
        C. Key Themes ("Users say...")
        D. Most Common Complaints
        E. Most Common Explanations / Theories
        F. Thread Vibe
        G. Highlighted Posts
           - 3 to 5 highlights using post number, user, page, post ID, upvotes, downvotes, vote score, reply count, and why it stood out
        H. Notable / High-Signal Moments
           - standout jokes, repeated bits, memes, trolling, or sharp observations
        I. Signal vs Noise
        J. Key Takeaways

        Engagement snapshot from extracted posts:
        {build_engagement_snapshot(thread.posts)}

        Intermediate chunk summaries:
        {joined_chunks}
        """
    ).strip()


def call_openai(client: OpenAI, model: str, prompt: str) -> str:
    response = client.responses.create(
        model=model,
        input=prompt,
    )
    return response.output_text.strip()


def summarize_thread(thread: ThreadData, model: str) -> str:
    api_key = os.getenv("OPENAI_API_KEY")
    if not api_key:
        raise RuntimeError("OPENAI_API_KEY is not set")

    client = OpenAI(api_key=api_key)
    chunks = chunk_posts(thread.posts)
    print("generating summary...", file=sys.stderr)

    chunk_summaries = []
    for index, chunk_text in enumerate(chunks, start=1):
        prompt = build_chunk_prompt(thread, chunk_text, index, len(chunks))
        chunk_summary = call_openai(client, model, prompt)
        chunk_summaries.append(chunk_summary)

    final_prompt = build_final_prompt(thread, chunk_summaries)
    return call_openai(client, model, final_prompt)


def main() -> int:
    load_env_file()
    args = parse_args()
    notify_projecthub = projecthub_notifications_enabled(args)

    try:
        thread_url = normalize_thread_url(args.url)
        if notify_projecthub:
            send_projecthub_message(f"TigerSummarizer started.\n\n{thread_url}")

        session = build_session()
        thread = crawl_thread(session, thread_url)
        print_app_event(
            "thread",
            title=thread.title,
            url=thread.first_page_url,
            pages=thread.verified_last_page,
            posts=len(thread.posts),
        )

        if not thread.posts:
            raise RuntimeError(
                "No posts were extracted. The page structure may have changed."
            )

        summary = summarize_thread(thread, args.model)
        saved_path = None
        if not args.no_save:
            output_path = args.output or default_summary_path(thread, args.output_dir)
            saved_path = save_summary(thread, summary, args.model, output_path)
            print(f"\nSaved summary: {saved_path}", file=sys.stderr)

        print(summary)
        if notify_projecthub:
            message = (
                "TigerSummarizer finished.\n\n"
                f"Title: {thread.title}\n"
                f"Posts: {len(thread.posts)}\n"
                f"Pages: {thread.verified_last_page}"
            )
            if saved_path:
                message += f"\nSaved: {saved_path}"
            send_projecthub_message(message)
        return 0
    except requests.HTTPError as exc:
        print(f"HTTP error: {exc}", file=sys.stderr)
        if notify_projecthub:
            send_projecthub_message(f"TigerSummarizer failed with an HTTP error.\n\n{exc}")
    except requests.RequestException as exc:
        print(f"Request failed: {exc}", file=sys.stderr)
        if notify_projecthub:
            send_projecthub_message(f"TigerSummarizer request failed.\n\n{exc}")
    except Exception as exc:  # pylint: disable=broad-except
        print(f"Error: {exc}", file=sys.stderr)
        if notify_projecthub:
            send_projecthub_message(f"TigerSummarizer failed.\n\n{exc}")

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
