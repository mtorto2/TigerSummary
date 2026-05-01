import { type CSSProperties, useEffect, useMemo, useState } from 'react';

type Mode = 'ready' | 'running' | 'done' | 'error' | 'notice';

export type SummaryState = {
  mode: Mode;
  title: string;
  subtitle: string;
  status: string;
  summary: string;
  savedPath?: string;
};

const initialState: SummaryState = {
  mode: 'ready',
  title: 'TigerDroppings Summarizer',
  subtitle: 'Copy a TigerDroppings thread URL, click TDS, then summarize.',
  status: 'Ready',
  summary:
    'Ready.\n\nCopy a TigerDroppings thread URL, click the TDS menu bar item, then choose Summarize Clipboard URL.',
};

function postAction(action: string) {
  window.webkit?.messageHandlers?.tigerAction?.postMessage({ action });
}

function parseSentiment(text: string) {
  const read = (label: string) => {
    const match = text.match(new RegExp(`${label}[^0-9]{0,20}(\\d{1,3})%`, 'i'));
    return match ? Math.max(0, Math.min(100, Number(match[1]))) : 0;
  };

  return {
    positive: read('Positive'),
    negative: read('Negative'),
    neutral: read('Neutral'),
  };
}

function normalizeMarkdownLine(line: string) {
  return line
    .trim()
    .replace(/^#{1,6}\s*/, '')
    .replace(/\*\*/g, '')
    .trim();
}

function parseTone(text: string) {
  const lines = text.split('\n');
  const sentimentIndex = lines.findIndex((line) => /^B\.\s+Overall Sentiment/i.test(normalizeMarkdownLine(line)));
  if (sentimentIndex === -1) return '';

  for (const line of lines.slice(sentimentIndex + 1, sentimentIndex + 8)) {
    const cleaned = normalizeMarkdownLine(line)
      .replace(/^[-*]\s*/, '')
      .replace(/^One-line description of tone:\s*/i, '')
      .trim();
    if (cleaned && !/Positive[^0-9]+\d+%/i.test(cleaned) && !/^Overall Sentiment/i.test(cleaned)) {
      return cleaned;
    }
  }
  return '';
}

function splitSections(text: string) {
  const lines = text.split('\n');
  const sections: Array<{ heading: string; body: string[] }> = [];
  let current: { heading: string; body: string[] } | null = null;

  for (const line of lines) {
    const trimmed = normalizeMarkdownLine(line);
    const isHeading = /^[A-J]\.\s/.test(trimmed) || (trimmed.endsWith(':') && trimmed.length < 80);

    if (isHeading) {
      if (current) sections.push(current);
      current = { heading: trimmed, body: [] };
    } else if (current) {
      current.body.push(line);
    } else if (trimmed) {
      current = { heading: 'Summary', body: [line] };
    }
  }

  if (current) sections.push(current);
  return sections.filter((section) => !/^B\.\s+Overall Sentiment/i.test(section.heading));
}

function SentimentGauge({ label, value, tone }: { label: string; value: number; tone: string }) {
  const style = { '--value': value } as CSSProperties;
  return (
    <div className="circleGauge">
      <div className={`circleTrack ${tone}`} style={style}>
        <strong>{value}%</strong>
      </div>
      <span>{label}</span>
    </div>
  );
}

function parseHighlightedPost(line: string) {
  const cleaned = normalizeMarkdownLine(line).replace(/^[-*]\s*/, '');
  const match = cleaned.match(/^(.*?)\s+[—-]\s+(.*)$/);
  const meta = match?.[1] ?? cleaned;
  const reason = match?.[2] ?? '';
  const parts = meta.split('|').map((part) => part.trim()).filter(Boolean);
  const post = parts.find((part) => /^Post\s+\d+/i.test(part));
  const page = parts.find((part) => /^page\s+\d+/i.test(part));
  const user = parts.find((part) => part !== post && part !== page && !/^post_?id\b/i.test(part) && !/^(upvotes|downvotes|score|vote_score|replies)\b/i.test(part));
  const readStat = (label: string) => {
    const stat = parts.find((part) => new RegExp(`^${label}\\b`, 'i').test(part));
    return stat?.replace(new RegExp(`^${label}\\s*=?\\s*`, 'i'), '') ?? '';
  };

  return {
    post: post || 'Post',
    user: user || 'Unknown user',
    page: page || '',
    upvotes: readStat('upvotes'),
    downvotes: readStat('downvotes'),
    score: readStat('score') || readStat('vote_score'),
    replies: readStat('replies'),
    reason,
  };
}

function HighlightedPost({ line }: { line: string }) {
  const post = parseHighlightedPost(line);
  const stats = [
    { label: 'Upvotes', icon: '↑', value: post.upvotes, className: 'up' },
    { label: 'Downvotes', icon: '↓', value: post.downvotes, className: 'down' },
    { label: 'Score', icon: '±', value: post.score, className: 'score' },
    { label: 'Replies', icon: '↩', value: post.replies, className: 'reply' },
  ].filter((stat) => stat.value !== '');

  return (
    <article className="highlightPost">
      <div className="highlightPostHeader">
        <div>
          <strong>{post.post}</strong>
          <span>{post.user}</span>
        </div>
        {post.page && <span className="pagePill">{post.page}</span>}
      </div>
      {stats.length > 0 && (
        <div className="highlightStats">
          {stats.map((stat) => (
            <span className={`statPill ${stat.className}`} key={stat.label} title={stat.label}>
              <span aria-hidden="true">{stat.icon}</span>
              {stat.value}
            </span>
          ))}
        </div>
      )}
      {post.reason && <p>{post.reason}</p>}
    </article>
  );
}

function SummaryBody({ text }: { text: string }) {
  const sections = useMemo(() => splitSections(text), [text]);

  if (!text.trim()) {
    return <p className="emptyText">Waiting for summary output...</p>;
  }

  return (
    <div className="summarySections">
      {sections.map((section, index) => (
        <section className="summarySection" key={`${section.heading}-${index}`}>
          <h2>{section.heading}</h2>
          <div className="sectionBody">
            {section.body.map((line, lineIndex) => {
              const trimmed = normalizeMarkdownLine(line);
              if (!trimmed) return <div className="spacer" key={lineIndex} />;
              if (/^G\.\s+Highlighted Posts/i.test(section.heading) && /^[-*]\s*Post\s+\d+/i.test(trimmed)) {
                return <HighlightedPost line={trimmed} key={lineIndex} />;
              }
              if (/^[-*]\s/.test(trimmed) || /^\d+\.\s/.test(trimmed)) {
                return <p className="bulletLine" key={lineIndex}>{trimmed}</p>;
              }
              return <p key={lineIndex}>{trimmed}</p>;
            })}
          </div>
        </section>
      ))}
    </div>
  );
}

export function App() {
  const [state, setState] = useState<SummaryState>(initialState);
  const sentiment = useMemo(() => parseSentiment(state.summary), [state.summary]);
  const tone = useMemo(() => parseTone(state.summary), [state.summary]);
  const isRunning = state.mode === 'running';

  useEffect(() => {
    window.TigerSummary = {
      setState: (nextState) => setState((current) => ({ ...current, ...nextState })),
      appendSummary: (text) => setState((current) => ({ ...current, summary: current.summary + text })),
      updateStatus: (status) => setState((current) => ({ ...current, status })),
    };
  }, []);

  return (
    <main className="shell">
      <header className="topBar">
        <div className="brand">
          <div className="badge">TDS</div>
          <div>
            <h1>{state.title}</h1>
            <p>{state.subtitle}</p>
          </div>
        </div>

        <aside className="sentimentCard" aria-label="Overall sentiment">
          <h2>Overall Sentiment</h2>
          <div className="sentimentPanel">
            <SentimentGauge label="Positive" value={sentiment.positive} tone="positive" />
            <SentimentGauge label="Negative" value={sentiment.negative} tone="negative" />
            <SentimentGauge label="Neutral" value={sentiment.neutral} tone="neutral" />
          </div>
          <p>{tone || 'Tone will appear here when the summary is ready.'}</p>
        </aside>
      </header>

      {isRunning && (
        <section className="progressFeature">
          <div>
            <div className="eyebrow">Processing Thread</div>
            <h2>{state.status || 'Summarizing...'}</h2>
          </div>
          <div className="animatedBar">
            <span />
          </div>
        </section>
      )}

      <section className={`reader ${state.mode}`}>
        <SummaryBody text={state.summary} />
      </section>

      <footer className="actionBar">
        <button type="button" onClick={() => postAction('copy')}>Copy</button>
        <button type="button" onClick={() => postAction('export')}>Export</button>
      </footer>
    </main>
  );
}
