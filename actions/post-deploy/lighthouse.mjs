// Runs Lighthouse in a Chrome page that answers HTTP basic auth challenges itself,
// so stylesheets Chrome refetches for CSS.enable get the credentials too.
// Usage: BASIC_AUTH=user:pass node lighthouse.mjs <url> <report.json> [desktop|mobile]
import fs from 'node:fs';
import puppeteer from 'puppeteer-core';
import lighthouse from 'lighthouse';
import desktopConfig from 'lighthouse/core/config/desktop-config.js';

const [url, out, formFactor = 'desktop'] = process.argv.slice(2);
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME_PATH,
  headless: true,
  args: ['--no-sandbox', '--disable-dev-shm-usage'],
});
let code = 0;
try {
  const page = await browser.newPage();
  const auth = process.env.BASIC_AUTH || '';
  if (auth) {
    const i = auth.indexOf(':');
    await page.authenticate({ username: auth.slice(0, i), password: auth.slice(i + 1) });
  }
  const result = await lighthouse(
    url,
    { output: 'json', logLevel: 'error', onlyCategories: ['performance', 'accessibility', 'best-practices', 'seo'] },
    formFactor === 'desktop' ? desktopConfig : undefined,
    page,
  );
  fs.writeFileSync(out, result.report);
  if (result.lhr.runtimeError) {
    console.error(`Runtime error encountered: ${result.lhr.runtimeError.message}`);
    code = 1;
  }
} finally {
  await browser.close();
}
process.exit(code);
