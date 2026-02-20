#!/usr/bin/env node
/**
 * CLI client for the Steward browser server.
 * Invoked by Tools::Executor. Reads STEWARD_USER_ID from env.
 *
 * Usage: node browser-client.js <command string>
 * Examples:
 *   node browser-client.js "open https://example.com"
 *   node browser-client.js "click 3"
 *   node browser-client.js "type 5 hello world"
 */

const http = require('http');

const SERVER_HOST = '127.0.0.1';
const SERVER_PORT = 18900;
const CLIENT_TIMEOUT = 55_000; // 55s, under the 60s tool timeout

function parseCommand(input) {
  const trimmed = input.trim();
  if (!trimmed) return { command: null, args: [] };

  const parts = trimmed.split(/\s+/);
  const command = parts[0].toLowerCase();

  // For type/fill/select: everything after the ref is one text argument
  if (['type', 'fill', 'select'].includes(command) && parts.length >= 3) {
    const ref = parts[1];
    const text = trimmed.slice(trimmed.indexOf(parts[1]) + parts[1].length).trim();
    return { command, args: [ref, text] };
  }

  return { command, args: parts.slice(1) };
}

function sendCommand(userId, command, args) {
  return new Promise((resolve, reject) => {
    const payload = JSON.stringify({ userId, command, args });

    const req = http.request({
      hostname: SERVER_HOST,
      port: SERVER_PORT,
      path: '/command',
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(payload),
      },
      timeout: CLIENT_TIMEOUT,
    }, (res) => {
      let body = '';
      res.on('data', chunk => body += chunk);
      res.on('end', () => {
        try {
          resolve(JSON.parse(body));
        } catch {
          reject(new Error(`Invalid response from browser server: ${body}`));
        }
      });
    });

    req.on('error', (e) => {
      if (e.code === 'ECONNREFUSED') {
        reject(new Error('Browser server is not running. Ask the administrator to start steward-browser.'));
      } else {
        reject(e);
      }
    });

    req.on('timeout', () => {
      req.destroy();
      reject(new Error('Browser command timed out after 55 seconds'));
    });

    req.write(payload);
    req.end();
  });
}

async function main() {
  const userId = process.env.STEWARD_USER_ID;
  if (!userId) {
    process.stderr.write('Error: STEWARD_USER_ID environment variable is required\n');
    process.exit(1);
  }

  const input = process.argv.slice(2).join(' ');
  if (!input) {
    process.stderr.write('Error: Command is required. Example: node browser-client.js "open https://example.com"\n');
    process.exit(1);
  }

  const { command, args } = parseCommand(input);
  if (!command) {
    process.stderr.write('Error: Empty command\n');
    process.exit(1);
  }

  try {
    const response = await sendCommand(userId, command, args);
    if (response.error) {
      process.stderr.write(`Error: ${response.error}\n`);
      process.exit(1);
    }
    process.stdout.write(response.result || '');
  } catch (e) {
    process.stderr.write(`Error: ${e.message}\n`);
    process.exit(1);
  }
}

main();
