#!/usr/bin/env node
/**
 * Persistent browser server for Steward agents.
 * Manages a single Chromium instance with per-user BrowserContexts.
 * HTTP server on 127.0.0.1:18900.
 *
 * Commands: open, snapshot, click, type, fill, select, check, uncheck,
 *           scroll, back, forward, refresh, wait, text, url, close
 */

const http = require('http');
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const PORT = 18900;
const HOST = '127.0.0.1';
const SESSION_DIR = path.resolve(__dirname, '..', '..', '..', 'data', 'browser-sessions');
const INACTIVITY_TIMEOUT_MS = 30 * 60 * 1000; // 30 minutes
const MAX_ELEMENTS = 100;
const MAX_CONTENT_LENGTH = 3000;
const NAVIGATION_TIMEOUT = 30_000;
const ACTION_TIMEOUT = 15_000;

let browser = null;
const sessions = new Map(); // userId -> { context, page, refs, timer }

// --- Browser Lifecycle ---

async function ensureBrowser() {
  if (browser && browser.isConnected()) return browser;
  log('Launching Chromium (full browser)...');
  browser = await chromium.launch({
    headless: true,
    executablePath: path.join(
      process.env.HOME, '.cache', 'ms-playwright', 'chromium-1208', 'chrome-linux64', 'chrome'
    ),
    args: ['--no-sandbox', '--disable-dev-shm-usage', '--disable-gpu'],
  });
  browser.on('disconnected', () => {
    log('Chromium disconnected unexpectedly');
    browser = null;
    // Clear all sessions — contexts are dead
    for (const [userId, session] of sessions) {
      clearTimeout(session.timer);
      sessions.delete(userId);
    }
  });
  log('Chromium launched');
  return browser;
}

// --- Session Management ---

function sessionDir(userId) {
  return path.join(SESSION_DIR, String(userId));
}

function storageStatePath(userId) {
  return path.join(sessionDir(userId), 'storage-state.json');
}

async function getSession(userId) {
  let session = sessions.get(userId);
  if (session) {
    resetInactivityTimer(userId);
    return session;
  }

  const b = await ensureBrowser();
  const dir = sessionDir(userId);
  fs.mkdirSync(dir, { recursive: true });

  const storagePath = storageStatePath(userId);
  const contextOpts = {
    userAgent: 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36',
    viewport: { width: 1280, height: 720 },
    javaScriptEnabled: true,
  };

  if (fs.existsSync(storagePath)) {
    try {
      contextOpts.storageState = storagePath;
    } catch (e) {
      log(`Failed to load storage state for user ${userId}: ${e.message}`);
    }
  }

  const context = await b.newContext(contextOpts);
  const page = await context.newPage();
  page.setDefaultTimeout(ACTION_TIMEOUT);

  session = { context, page, refs: new Map(), timer: null, crashed: false };

  // Listen for page crashes to flag the session
  page.on('crash', () => {
    log(`Page crashed for user ${userId}`);
    session.crashed = true;
  });

  sessions.set(userId, session);
  resetInactivityTimer(userId);
  return session;
}

async function recoverPage(userId) {
  const session = sessions.get(userId);
  if (!session) return null;

  log(`Recovering page for user ${userId}...`);
  try { await session.page.close(); } catch (e) { /* already dead */ }

  const page = await session.context.newPage();
  page.setDefaultTimeout(ACTION_TIMEOUT);
  session.page = page;
  session.crashed = false;
  session.refs = new Map();

  page.on('crash', () => {
    log(`Page crashed for user ${userId}`);
    session.crashed = true;
  });

  return session;
}

async function saveSession(userId) {
  const session = sessions.get(userId);
  if (!session) return;
  try {
    const dir = sessionDir(userId);
    fs.mkdirSync(dir, { recursive: true });
    await session.context.storageState({ path: storageStatePath(userId) });
  } catch (e) {
    log(`Failed to save session for user ${userId}: ${e.message}`);
  }
}

async function closeSession(userId) {
  const session = sessions.get(userId);
  if (!session) return;
  clearTimeout(session.timer);
  await saveSession(userId);
  try { await session.context.close(); } catch (e) { /* ignore */ }
  sessions.delete(userId);
}

function resetInactivityTimer(userId) {
  const session = sessions.get(userId);
  if (!session) return;
  if (session.timer) clearTimeout(session.timer);
  session.timer = setTimeout(async () => {
    log(`Session for user ${userId} timed out due to inactivity`);
    await closeSession(userId);
  }, INACTIVITY_TIMEOUT_MS);
}

// --- Ref System ---

async function buildSnapshot(page, refs) {
  refs.clear();

  const result = await page.evaluate(({ maxElements, maxContent }) => {
    const title = document.title || '';
    const url = document.location.href;

    // Extract page text content (truncated)
    const bodyClone = document.body.cloneNode(true);
    for (const tag of ['script', 'style', 'noscript', 'svg']) {
      bodyClone.querySelectorAll(tag).forEach(el => el.remove());
    }
    let textContent = bodyClone.innerText || bodyClone.textContent || '';
    textContent = textContent.replace(/[ \t]+/g, ' ').replace(/\n{3,}/g, '\n\n').trim();
    if (textContent.length > maxContent) {
      textContent = textContent.slice(0, maxContent) + '\n... (truncated, use "text" command for full content)';
    }

    // Find interactive elements
    const selectors = [
      'a[href]',
      'button',
      'input:not([type="hidden"])',
      'textarea',
      'select',
      '[role="button"]',
      '[role="link"]',
      '[role="checkbox"]',
      '[role="tab"]',
      '[contenteditable="true"]',
    ];

    const seen = new Set();
    const elements = [];

    for (const selector of selectors) {
      for (const el of document.querySelectorAll(selector)) {
        if (seen.has(el)) continue;
        if (elements.length >= maxElements) break;

        // Skip invisible elements
        const style = window.getComputedStyle(el);
        if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') continue;
        const rect = el.getBoundingClientRect();
        if (rect.width === 0 && rect.height === 0) continue;

        seen.add(el);

        const tag = el.tagName.toLowerCase();
        const type = el.getAttribute('type') || '';
        const role = el.getAttribute('role') || '';
        const name = el.getAttribute('name') || '';
        const ariaLabel = el.getAttribute('aria-label') || '';
        const placeholder = el.getAttribute('placeholder') || '';
        const text = (el.innerText || el.textContent || '').trim().slice(0, 80);
        const value = el.value || '';
        const checked = el.checked;
        const href = el.getAttribute('href') || '';

        // Build a unique path for re-finding
        let cssPath = '';
        try {
          // Build a reasonably specific selector
          const parts = [];
          let current = el;
          for (let i = 0; i < 5 && current && current !== document.body; i++) {
            let part = current.tagName.toLowerCase();
            if (current.id) {
              part = '#' + CSS.escape(current.id);
              parts.unshift(part);
              break;
            }
            if (current.className && typeof current.className === 'string') {
              const classes = current.className.trim().split(/\s+/).slice(0, 2);
              if (classes.length > 0 && classes[0]) {
                part += '.' + classes.map(c => CSS.escape(c)).join('.');
              }
            }
            if (name && current === el) {
              part += `[name="${CSS.escape(name)}"]`;
            }
            parts.unshift(part);
            current = current.parentElement;
          }
          cssPath = parts.join(' > ');
        } catch (e) {
          cssPath = tag;
        }

        // Assign data attribute
        const refIndex = elements.length + 1;
        el.setAttribute('data-steward-ref', String(refIndex));

        let description = '';
        if (tag === 'a') {
          description = `link "${text || href}"`;
        } else if (tag === 'button' || role === 'button') {
          description = `button "${text || ariaLabel}"`;
        } else if (tag === 'input') {
          const inputType = type || 'text';
          if (inputType === 'checkbox' || inputType === 'radio') {
            const label = ariaLabel || text || name;
            description = `${inputType} "${label}" checked=${checked}`;
          } else {
            const label = ariaLabel || placeholder || name;
            description = `input[${inputType}] "${label}" value="${value.slice(0, 50)}"`;
          }
        } else if (tag === 'textarea') {
          const label = ariaLabel || placeholder || name;
          description = `textarea "${label}" value="${value.slice(0, 50)}"`;
        } else if (tag === 'select') {
          const label = ariaLabel || name;
          const selected = el.options?.[el.selectedIndex]?.text || '';
          description = `select "${label}" selected="${selected}"`;
        } else if (role === 'checkbox') {
          const label = ariaLabel || text;
          description = `checkbox "${label}" checked=${el.getAttribute('aria-checked') === 'true'}`;
        } else if (role === 'tab') {
          description = `tab "${text || ariaLabel}"`;
        } else if (role === 'link') {
          description = `link "${text || ariaLabel}"`;
        } else {
          description = `${tag}[${role || 'interactive'}] "${text || ariaLabel}"`;
        }

        elements.push({
          ref: refIndex,
          description,
          selector: `[data-steward-ref="${refIndex}"]`,
          cssPath,
        });
      }
      if (elements.length >= maxElements) break;
    }

    return { title, url, textContent, elements };
  }, { maxElements: MAX_ELEMENTS, maxContent: MAX_CONTENT_LENGTH });

  // Store ref mappings server-side
  for (const el of result.elements) {
    refs.set(el.ref, { selector: el.selector, cssPath: el.cssPath });
  }

  // Format output
  let output = `Page: ${result.title}\nURL: ${result.url}\n`;
  output += `\n--- Page Content ---\n${result.textContent}\n`;
  output += `\n--- Interactive Elements ---\n`;

  if (result.elements.length === 0) {
    output += '(No interactive elements found)\n';
  } else {
    for (const el of result.elements) {
      output += `[${el.ref}] ${el.description}\n`;
    }
  }

  output += `\nTip: Use click <ref>, type <ref> <text>, select <ref> <value>`;
  return output;
}

async function resolveRef(page, refs, refNum) {
  const ref = refs.get(refNum);
  if (!ref) throw new Error(`Invalid ref [${refNum}]. Use "snapshot" to get current refs.`);

  // Try data-attribute first (most reliable)
  let el = await page.$(ref.selector);
  if (el) return el;

  // Fallback to CSS path
  if (ref.cssPath) {
    el = await page.$(ref.cssPath);
    if (el) return el;
  }

  throw new Error(`Element [${refNum}] no longer found on page. Use "snapshot" to get updated refs.`);
}

// --- Command Handlers ---

async function handleCommand(userId, command, args) {
  let session = await getSession(userId);

  // Recover from page crash before executing any command
  if (session.crashed) {
    session = await recoverPage(userId);
    if (!session) return { error: 'Failed to recover from page crash. Try "close" then start again.' };
    log(`Page recovered for user ${userId}`);
  }

  let { page, refs } = session;

  switch (command) {
    case 'open': {
      let url = args[0];
      if (!url) return { error: 'Usage: open <url>' };
      if (!url.startsWith('http')) url = 'https://' + url;
      try { new URL(url); } catch { return { error: `Invalid URL: ${url}` }; }
      try {
        await page.goto(url, { waitUntil: 'domcontentloaded', timeout: NAVIGATION_TIMEOUT });
      } catch (e) {
        if (e.message.includes('Page crashed') || e.message.includes('Target closed') || session.crashed) {
          // Recover and retry once
          session = await recoverPage(userId);
          if (!session) return { error: 'Browser page crashed and recovery failed.' };
          page = session.page;
          refs = session.refs;
          await page.goto(url, { waitUntil: 'domcontentloaded', timeout: NAVIGATION_TIMEOUT });
        } else {
          throw e;
        }
      }
      await page.waitForTimeout(1500);
      await saveSession(userId);
      const snapshot = await buildSnapshot(page, refs);
      return { result: snapshot };
    }

    case 'snapshot': {
      const snapshot = await buildSnapshot(page, refs);
      return { result: snapshot };
    }

    case 'click': {
      const refNum = parseInt(args[0]);
      if (isNaN(refNum)) return { error: 'Usage: click <ref>' };
      const el = await resolveRef(page, refs, refNum);
      // Use Promise.all to handle navigation that might occur
      const [response] = await Promise.all([
        page.waitForNavigation({ waitUntil: 'domcontentloaded', timeout: NAVIGATION_TIMEOUT }).catch(() => null),
        el.click(),
      ]);
      await page.waitForTimeout(1000);
      await saveSession(userId);
      const snapshot = await buildSnapshot(page, refs);
      return { result: snapshot };
    }

    case 'type': {
      const refNum = parseInt(args[0]);
      if (isNaN(refNum) || args.length < 2) return { error: 'Usage: type <ref> <text>' };
      const text = args.slice(1).join(' ');
      const el = await resolveRef(page, refs, refNum);
      await el.click({ clickCount: 3 }); // select all
      await el.type(text);
      await saveSession(userId);
      const snapshot = await buildSnapshot(page, refs);
      return { result: snapshot };
    }

    case 'fill': {
      const refNum = parseInt(args[0]);
      if (isNaN(refNum) || args.length < 2) return { error: 'Usage: fill <ref> <text>' };
      const text = args.slice(1).join(' ');
      const el = await resolveRef(page, refs, refNum);
      await el.fill(text);
      await saveSession(userId);
      const snapshot = await buildSnapshot(page, refs);
      return { result: snapshot };
    }

    case 'select': {
      const refNum = parseInt(args[0]);
      if (isNaN(refNum) || args.length < 2) return { error: 'Usage: select <ref> <value>' };
      const value = args.slice(1).join(' ');
      const el = await resolveRef(page, refs, refNum);
      await el.selectOption({ label: value });
      await saveSession(userId);
      const snapshot = await buildSnapshot(page, refs);
      return { result: snapshot };
    }

    case 'check': {
      const refNum = parseInt(args[0]);
      if (isNaN(refNum)) return { error: 'Usage: check <ref>' };
      const el = await resolveRef(page, refs, refNum);
      await el.check();
      await saveSession(userId);
      const snapshot = await buildSnapshot(page, refs);
      return { result: snapshot };
    }

    case 'uncheck': {
      const refNum = parseInt(args[0]);
      if (isNaN(refNum)) return { error: 'Usage: uncheck <ref>' };
      const el = await resolveRef(page, refs, refNum);
      await el.uncheck();
      await saveSession(userId);
      const snapshot = await buildSnapshot(page, refs);
      return { result: snapshot };
    }

    case 'scroll': {
      const direction = (args[0] || 'down').toLowerCase();
      const amount = direction === 'up' ? -600 : 600;
      await page.evaluate((y) => window.scrollBy(0, y), amount);
      await page.waitForTimeout(500);
      const snapshot = await buildSnapshot(page, refs);
      return { result: snapshot };
    }

    case 'back': {
      await page.goBack({ waitUntil: 'domcontentloaded', timeout: NAVIGATION_TIMEOUT }).catch(() => null);
      await page.waitForTimeout(1000);
      await saveSession(userId);
      const snapshot = await buildSnapshot(page, refs);
      return { result: snapshot };
    }

    case 'forward': {
      await page.goForward({ waitUntil: 'domcontentloaded', timeout: NAVIGATION_TIMEOUT }).catch(() => null);
      await page.waitForTimeout(1000);
      await saveSession(userId);
      const snapshot = await buildSnapshot(page, refs);
      return { result: snapshot };
    }

    case 'refresh': {
      await page.reload({ waitUntil: 'domcontentloaded', timeout: NAVIGATION_TIMEOUT });
      await page.waitForTimeout(1000);
      await saveSession(userId);
      const snapshot = await buildSnapshot(page, refs);
      return { result: snapshot };
    }

    case 'wait': {
      await page.waitForTimeout(2000);
      const snapshot = await buildSnapshot(page, refs);
      return { result: snapshot };
    }

    case 'text': {
      const text = await page.evaluate(() => {
        const clone = document.body.cloneNode(true);
        for (const tag of ['script', 'style', 'noscript', 'svg']) {
          clone.querySelectorAll(tag).forEach(el => el.remove());
        }
        return (clone.innerText || clone.textContent || '').replace(/[ \t]+/g, ' ').replace(/\n{3,}/g, '\n\n').trim();
      });
      const maxText = 40_000;
      const truncated = text.length > maxText ? text.slice(0, maxText) + '\n... (truncated)' : text;
      return { result: `URL: ${page.url()}\n\n${truncated}` };
    }

    case 'url': {
      return { result: page.url() };
    }

    case 'close': {
      await closeSession(userId);
      return { result: 'Browser session closed.' };
    }

    default:
      return { error: `Unknown command: ${command}. Available: open, snapshot, click, type, fill, select, check, uncheck, scroll, back, forward, refresh, wait, text, url, close` };
  }
}

// --- HTTP Server ---

const server = http.createServer(async (req, res) => {
  if (req.method === 'GET' && req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: true, sessions: sessions.size, browser: browser?.isConnected() ?? false }));
    return;
  }

  if (req.method === 'POST' && req.url === '/command') {
    let body = '';
    req.on('data', chunk => body += chunk);
    req.on('end', async () => {
      try {
        const { userId, command, args } = JSON.parse(body);
        if (!userId) {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'userId is required' }));
          return;
        }
        if (!command) {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'command is required' }));
          return;
        }

        let result = await handleCommand(String(userId), command, args || []);

        // If the command itself errored with a crash-like message, try recovering
        if (result.error && /page crashed|target closed|context.*destroyed/i.test(result.error)) {
          log(`Crash detected in result for user ${userId}, attempting recovery...`);
          const recovered = await recoverPage(String(userId));
          if (recovered) {
            result = { error: `Page crashed and was recovered. Please retry your command.` };
          }
        }

        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(result));
      } catch (e) {
        const msg = e.message || String(e);
        log(`Error handling command: ${msg}`);

        // Attempt recovery on crash errors
        if (/page crashed|target closed|context.*destroyed/i.test(msg)) {
          try {
            const uid = JSON.parse(body).userId;
            if (uid) await recoverPage(String(uid));
          } catch (re) { /* best effort */ }
        }

        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: msg }));
      }
    });
    return;
  }

  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: 'Not found' }));
});

// --- Lifecycle ---

function log(msg) {
  const ts = new Date().toISOString();
  process.stderr.write(`[${ts}] ${msg}\n`);
}

async function shutdown() {
  log('Shutting down...');
  // Save all sessions
  for (const [userId] of sessions) {
    await closeSession(userId);
  }
  if (browser) {
    await browser.close().catch(() => {});
  }
  server.close();
  log('Shutdown complete');
  process.exit(0);
}

process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);

server.listen(PORT, HOST, () => {
  log(`Browser server listening on ${HOST}:${PORT}`);
});
