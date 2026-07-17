#!/usr/bin/env node
// run.mjs — runs one backend over the fixtures/manifest.json meeting set,
// producing Call ③ prompts from the live DB (re-extracted each run — never
// stored in git-tracked files) and writing outputs to a gitignored
// runs/<backend>-<label>/ directory: one JSON file per meeting plus a
// run-level summary.
//
// Usage:
//   node run.mjs --backend llama --label baseline
//   node run.mjs --backend apple --label probe-check
//   node run.mjs --backend ollama --label gemma3-1b --model gemma3:1b
//   node run.mjs --backend mlx --label qwen-mlx            # MLX Qwen3.5-4B (S1 candidate)
//   node run.mjs --backend gemma --label gemma-e4b         # MLX Gemma 4 E4B (S1 candidate)
//
// Each backend module exports run({system, user}, opts) -> Promise<{text}>.

import fs from 'node:fs';
import path from 'node:path';
import { openReadOnly, loadTranscript, DEFAULT_DB_PATH } from './lib/db.mjs';
import { loadTemplate, buildCallThreePrompt } from './lib/prompt.mjs';

const TEMPLATES_DIR = path.resolve(import.meta.dirname, '../../frontend/src-tauri/templates');

function parseArgs(argv) {
  const args = { db: DEFAULT_DB_PATH, backend: null, label: null, model: null, templateId: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--db') args.db = argv[++i];
    else if (a === '--backend') args.backend = argv[++i];
    else if (a === '--label') args.label = argv[++i];
    else if (a === '--model') args.model = argv[++i];
    else if (a === '--template') args.templateId = argv[++i];
    else if (a === '--limit') args.limit = parseInt(argv[++i], 10);
  }
  return args;
}

async function loadBackend(name) {
  switch (name) {
    case 'llama':
      return import('./lib/backends/llama.mjs');
    case 'apple':
      return import('./lib/backends/apple.mjs');
    case 'ollama':
      return import('./lib/backends/ollama.mjs');
    case 'mlx':
      return import('./lib/backends/mlx.mjs');
    case 'gemma':
      return import('./lib/backends/gemma.mjs');
    default:
      throw new Error(`Unknown backend '${name}'. Use llama | apple | ollama | mlx | gemma.`);
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (!args.backend || !args.label) {
    console.error('Usage: node run.mjs --backend <llama|apple|ollama|mlx|gemma> --label <name> [--model NAME] [--template ID] [--limit N]');
    process.exit(1);
  }

  const manifestPath = path.resolve(import.meta.dirname, 'fixtures/manifest.json');
  if (!fs.existsSync(manifestPath)) {
    console.error(`No fixtures/manifest.json found. Run: node extract.mjs`);
    process.exit(1);
  }
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  let meetings = manifest.meetings;
  if (args.limit) meetings = meetings.slice(0, args.limit);

  const backendModule = await loadBackend(args.backend);
  const db = openReadOnly(args.db);

  const outDir = path.resolve(import.meta.dirname, `runs/${args.backend}-${args.label}`);
  fs.mkdirSync(outDir, { recursive: true });

  const runOpts = {};
  if (args.model) runOpts.model = args.model;

  const results = [];
  for (const meetingMeta of meetings) {
    const { transcriptText, lines } = loadTranscript(db, meetingMeta.id);
    if (!transcriptText.trim()) {
      console.warn(`[skip] ${meetingMeta.id} has no transcript text`);
      continue;
    }

    const templateId = args.templateId || meetingMeta.templateId || 'standard_meeting';
    let template;
    try {
      template = loadTemplate(templateId, TEMPLATES_DIR);
    } catch (err) {
      console.warn(`[skip] ${meetingMeta.id}: could not load template '${templateId}': ${err.message}`);
      continue;
    }

    const { system, user } = buildCallThreePrompt(transcriptText, template);

    console.log(`[${args.backend}] "${meetingMeta.title}" (${lines.length} lines, template=${templateId}) ...`);
    const start = Date.now();
    let outcome;
    try {
      // Spread the full backend result (not just `text`) so MLX backends'
      // extra cost fields (latencyMs, loadMs, peakRssMb, model) survive into
      // the persisted record for compare.mjs to read.
      const backendResult = await backendModule.run({ system, user }, runOpts);
      const { text } = backendResult;
      outcome = { ok: true, ...backendResult, text, elapsedMs: Date.now() - start };
      console.log(`  -> ${text.length} chars in ${outcome.elapsedMs}ms`);
    } catch (err) {
      outcome = { ok: false, error: err.message, elapsedMs: Date.now() - start };
      console.warn(`  -> FAILED: ${err.message}`);
    }

    const record = {
      meetingId: meetingMeta.id,
      title: meetingMeta.title,
      templateId,
      backend: args.backend,
      model: args.model || null,
      lineCount: lines.length,
      ...outcome,
    };
    results.push(record);
    fs.writeFileSync(path.join(outDir, `${meetingMeta.id}.json`), JSON.stringify(record, null, 2) + '\n');
  }

  const summary = {
    backend: args.backend,
    label: args.label,
    model: args.model || null,
    generatedAt: new Date().toISOString(),
    total: results.length,
    succeeded: results.filter((r) => r.ok).length,
    failed: results.filter((r) => !r.ok).length,
  };
  fs.writeFileSync(path.join(outDir, '_summary.json'), JSON.stringify(summary, null, 2) + '\n');
  console.log(`\nDone: ${summary.succeeded}/${summary.total} succeeded. Output: ${outDir}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
