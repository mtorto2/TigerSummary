import fs from 'node:fs';
import path from 'node:path';

const rootDir = path.resolve(new URL('..', import.meta.url).pathname);
const webDir = path.join(rootDir, 'build', 'web');
const assetsDir = path.join(webDir, 'assets');
const indexPath = path.join(webDir, 'index.html');

const files = fs.readdirSync(assetsDir);
const cssFile = files.find((file) => file.endsWith('.css'));
const jsFile = files.find((file) => file.endsWith('.js'));

if (!cssFile || !jsFile) {
  throw new Error(`Missing built CSS or JS in ${assetsDir}`);
}

const css = fs.readFileSync(path.join(assetsDir, cssFile), 'utf8');
const js = fs.readFileSync(path.join(assetsDir, jsFile), 'utf8');

const html = `<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>TigerDroppings Summarizer</title>
    <style>${css}</style>
  </head>
  <body>
    <div id="root"></div>
    <script>${js}</script>
  </body>
</html>
`;

fs.writeFileSync(indexPath, html);
