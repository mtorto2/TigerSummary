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

function normalizeSectionHeading(heading: string) {
  if (/^C\.\s+Key Themes/i.test(heading)) {
    return 'C. Users say...';
  }
  return heading;
}

function formatSectionLine(sectionHeading: string, line: string) {
  const trimmed = normalizeMarkdownLine(line);
  if (!/^C\.\s+Users say\.\.\./i.test(sectionHeading)) {
    return trimmed;
  }

  return trimmed.replace(/^([-*]\s*)Users say\s+(.+)$/i, (_match, bullet: string, content: string) => {
    const cleaned = content.trim();
    return `${bullet}${cleaned.charAt(0).toUpperCase()}${cleaned.slice(1)}`;
  });
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
      current = { heading: normalizeSectionHeading(trimmed), body: [] };
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
  const rawReason = match?.[2] ?? '';
  const parts = meta.split('|').map((part) => part.trim()).filter(Boolean);
  const postPart = parts.find((part) => /^Post\s*#?\s*\d+/i.test(part));
  const pagePart = parts.find((part) => /^page\s*=?\s*\d+/i.test(part));
  const normalizeUser = (value: string) => value
    .replace(/^(user|username)\s*[:=]\s*/i, '')
    .trim();
  const userPart = parts.find((part) => {
    const normalized = normalizeUser(part);
    return part !== postPart
      && part !== pagePart
      && normalized
      && !/^unknown(?:\s+user)?$/i.test(normalized)
      && !/^post_?id\b/i.test(part)
      && !/^(upvotes|downvotes|score|vote_score|vote score|replies|reply_count|reply count)\b/i.test(part);
  });
  const readStat = (labels: string[]) => {
    for (const label of labels) {
      const pattern = label.replace(/\s+/g, '[ _-]?');
      const stat = parts.find((part) => new RegExp(`^${pattern}\\b`, 'i').test(part));
      const value = stat?.replace(new RegExp(`^${pattern}\\s*[:=]?\\s*`, 'i'), '').trim();
      if (value) return value;
    }
    return '';
  };
  const stripMetricText = (value: string) => value
    .replace(/\bpost_?id\s*[:=]?\s*\d+\s*\|?/gi, '')
    .replace(/\bupvotes?\s*[:=]?\s*-?\d+\s*\|?/gi, '')
    .replace(/\bdownvotes?\s*[:=]?\s*-?\d+\s*\|?/gi, '')
    .replace(/\b(?:vote\s*score|vote_score|score)\s*[:=]?\s*-?\d+\s*\|?/gi, '')
    .replace(/\b(?:reply\s*count|reply_count|replies)\s*[:=]?\s*-?\d+\s*\|?/gi, '')
    .replace(/\s{2,}/g, ' ')
    .replace(/^\s*[|,;-]+\s*/, '')
    .trim();

  return {
    post: postPart || 'Post',
    user: userPart ? normalizeUser(userPart) : '',
    page: pagePart?.replace(/^page\s*=?\s*/i, 'page ') ?? '',
    upvotes: readStat(['upvotes', 'upvote']),
    downvotes: readStat(['downvotes', 'downvote']),
    score: readStat(['score', 'vote_score', 'vote score']),
    replies: readStat(['replies', 'reply_count', 'reply count']),
    reason: stripMetricText(rawReason),
  };
}

function HighlightedPost({ line }: { line: string }) {
  const post = parseHighlightedPost(line);
  const stats = [
    { label: 'Upvotes', icon: '👍', value: post.upvotes, className: 'up' },
    { label: 'Downvotes', icon: '👎', value: post.downvotes, className: 'down' },
    { label: 'Score', icon: '★', value: post.score, className: 'score' },
    { label: 'Replies', icon: '💬', value: post.replies, className: 'reply' },
  ].filter((stat) => stat.value !== '');

  return (
    <article className="highlightPost">
      <div className="highlightPostHeader">
        <div>
          <strong>{post.post}</strong>
          {post.user && <span>{post.user}</span>}
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
              const trimmed = formatSectionLine(section.heading, line);
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
