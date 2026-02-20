#!/usr/bin/env node
/**
 * Browse a web page using headless Chromium via Playwright.
 * Renders JavaScript, extracts clean text content.
 *
 * Usage: node browse.js <url>
 * Output: Page title + readable text content (stdout)
 * Errors: Descriptive messages (stderr, exit 1)
 */

const { chromium } = require('playwright');

const MAX_LENGTH = 40_000;
const NAVIGATION_TIMEOUT = 25_000;
const PAGE_TIMEOUT = 30_000;

async function main() {
  const url = process.argv[2]?.trim();
  if (!url) {
    process.stderr.write('Error: URL is required\n');
    process.exit(1);
  }

  // Basic URL validation
  let parsedUrl;
  try {
    parsedUrl = new URL(url.startsWith('http') ? url : `https://${url}`);
  } catch {
    process.stderr.write(`Error: Invalid URL "${url}"\n`);
    process.exit(1);
  }

  let browser;
  try {
    browser = await chromium.launch({
      headless: true,
      args: ['--no-sandbox', '--disable-dev-shm-usage', '--disable-gpu'],
    });

    const context = await browser.newContext({
      userAgent: 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36',
      viewport: { width: 1280, height: 720 },
      javaScriptEnabled: true,
    });

    const page = await context.newPage();
    page.setDefaultTimeout(PAGE_TIMEOUT);

    // Block unnecessary resources to speed up loading
    await page.route('**/*', (route) => {
      const type = route.request().resourceType();
      if (['image', 'media', 'font', 'stylesheet'].includes(type)) {
        route.abort();
      } else {
        route.continue();
      }
    });

    // Navigate
    const response = await page.goto(parsedUrl.href, {
      waitUntil: 'domcontentloaded',
      timeout: NAVIGATION_TIMEOUT,
    });

    if (!response) {
      process.stderr.write('Error: No response received\n');
      process.exit(1);
    }

    const status = response.status();
    if (status >= 400) {
      process.stderr.write(`Error: HTTP ${status} ${response.statusText()}\n`);
      process.exit(1);
    }

    // Wait a bit for JS rendering to settle
    await page.waitForTimeout(2000);

    // Extract page content
    const data = await page.evaluate(() => {
      const title = document.title || '';
      const url = document.location.href;

      // Remove script/style/nav/footer/header elements for cleaner text
      const clone = document.body.cloneNode(true);
      for (const tag of ['script', 'style', 'noscript', 'svg', 'nav', 'footer', 'header', 'iframe']) {
        clone.querySelectorAll(tag).forEach(el => el.remove());
      }

      // Try to find main content area
      const main = clone.querySelector('main, article, [role="main"], .content, #content, .post, .article');
      const source = main || clone;

      // Extract text with some structure preserved
      const lines = [];
      const walker = document.createTreeWalker(source, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, null);
      let lastWasBlock = false;

      while (walker.nextNode()) {
        const node = walker.currentNode;

        if (node.nodeType === Node.TEXT_NODE) {
          const text = node.textContent.trim();
          if (text) {
            lines.push(text);
            lastWasBlock = false;
          }
        } else if (node.nodeType === Node.ELEMENT_NODE) {
          const tag = node.tagName.toLowerCase();
          const blockTags = ['p', 'div', 'br', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'li', 'tr', 'blockquote', 'pre', 'section'];
          if (blockTags.includes(tag) && !lastWasBlock) {
            lines.push('\n');
            lastWasBlock = true;
          }
          // Add markdown-style headers
          if (/^h[1-6]$/.test(tag)) {
            const level = parseInt(tag[1]);
            lines.push('#'.repeat(level) + ' ');
          }
        }
      }

      // Also extract links for reference
      const links = [];
      source.querySelectorAll('a[href]').forEach(a => {
        const text = a.textContent.trim();
        const href = a.href;
        if (text && href && !href.startsWith('javascript:')) {
          links.push(`[${text}](${href})`);
        }
      });

      return { title, url, text: lines.join(' '), links: links.slice(0, 30) };
    });

    // Clean up the text
    let content = data.text
      .replace(/[ \t]+/g, ' ')      // collapse spaces
      .replace(/ \n /g, '\n')       // clean around newlines
      .replace(/\n{3,}/g, '\n\n')   // max 2 consecutive newlines
      .trim();

    // Build output
    let output = '';
    if (data.title) {
      output += `# ${data.title}\nURL: ${data.url}\n\n`;
    }

    if (!content) {
      output += '(No text content extracted — page may require interaction or login)\n';
    } else {
      if (content.length > MAX_LENGTH) {
        content = content.slice(0, MAX_LENGTH) + '\n\n... (content truncated)';
      }
      output += content;
    }

    // Append key links
    if (data.links.length > 0) {
      output += '\n\n---\nKey links on page:\n';
      for (const link of data.links) {
        output += `- ${link}\n`;
      }
    }

    process.stdout.write(output);

    await browser.close();
  } catch (err) {
    if (browser) await browser.close().catch(() => {});

    if (err.message.includes('Timeout')) {
      process.stderr.write(`Error: Page load timed out after ${NAVIGATION_TIMEOUT / 1000}s\n`);
    } else {
      process.stderr.write(`Error: ${err.message}\n`);
    }
    process.exit(1);
  }
}

main();
