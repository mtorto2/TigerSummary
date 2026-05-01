import { createRoot } from 'react-dom/client';
import './styles.css';
import { App, type SummaryState } from './App';

declare global {
  interface Window {
    TigerSummary?: {
      setState: (nextState: Partial<SummaryState>) => void;
      appendSummary: (text: string) => void;
      updateStatus: (status: string) => void;
    };
    webkit?: {
      messageHandlers?: {
        tigerAction?: {
          postMessage: (message: unknown) => void;
        };
      };
    };
  }
}

const root = createRoot(document.getElementById('root')!);
root.render(<App />);
