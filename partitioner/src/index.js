#!/usr/bin/env node

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');
const glob = require('glob');
const parquet = require('parquetjs');
const readline = require('readline');

// for local testing, you can change this to a different path but
// AWS Batch uses /tmp to provide ephemeral storage so it needs to be /tmp
// when run in production
const root = '/tmp/data';

// for production run all the steps
// for development you can comment out steps you don't want to run
const steps = [
  "download",
  "parse",
  "split",
  "merge",
  "upload",
  "clean"
];

const nullValuePlaceholder = 'none';

const staticSchema = new parquet.ParquetSchema({
  id: { type: 'UTF8' },
  session: { type: 'UTF8' },
  username: { type: 'UTF8' },
  application: { type: 'UTF8' },
  activity: { type: 'UTF8' },
  event: { type: 'UTF8' },
  time: { type: 'INT64' },
  parameters: { type: 'UTF8' },
  extras: { type: 'UTF8' },
  event_value: { type: 'UTF8' },
  run_remote_endpoint: { type: 'UTF8' },
  timestamp: { type: 'INT64' }
});

const validBuckets = ['log-ingester-production', 'log-ingester-qa'];
const bucket = process.env.AWS_S3_BUCKET;
if (!bucket) {
  console.error("Missing AWS_S3_BUCKET environment variable!");
  process.exit(1);
}
if (!validBuckets.includes(bucket)) {
  console.error(`Invalid AWS_S3_BUCKET: ${bucket}. Must be one of ${validBuckets.join(' or ')}.`);
  process.exit(1);
}

const args = process.argv.slice(2);
if (args.length > 1) {
  console.log('Usage: node index.js [YYYY-MM-DD]');
  console.log('If no date is provided, yesterday\'s date will be used.');
  process.exit(1);
}

let ymd = null;
let year = null;
let month = null;
let day = null;

const checkDateString = (str, source) => {
  if (/^\d{4}-\d{2}-\d{2}$/.test(str)) {
    if (isNaN((new Date(str)).getTime())) {
      console.error(`Invalid date provided as ${source}: ${str}`);
      process.exit(1);
    }
  } else {
    console.error(`Invalid date format provided as ${source}. Expected YYYY-MM-DD, got: ${str}`);
    process.exit(1);
  }
  return str;
};

if (args.length > 1) {
  ymd = args[1];
  ymd = checkDateString(ymd, 'arg');
} else if (process.env.LOG_DATE) {
  ymd = checkDateString(process.env.LOG_DATE, 'LOG_DATE env var');
} else {
  // use yesterday's date if no date is specified
  const date = new Date();
  date.setDate(date.getDate() - 1);
  year = date.getFullYear().toString();
  month = (date.getMonth() + 1).toString().padStart(2, '0');
  day = date.getDate().toString().padStart(2, '0');
  ymd = checkDateString(`${year}-${month}-${day}`, "calculated yesterday's date");
}

const parts = ymd.split('-');
if (parts.length !== 3) {
  console.error(`Invalid date format. Expected YYYY-MM-DD, got: ${ymd}`);
  process.exit(1);
}
year = parts[0];
month = parts[1].padStart(2, '0');
day = parts[2].padStart(2, '0');

const log = (message) => console.log(`${ymd}: ${message}`);

log(`Starting processing: ${JSON.stringify({bucket, year, month, day})}`);

(async () => {
  const s3Prefix = `processed_logs_with_id/${year}/${month}/${day}`;
  const uploadPrefix = `logs_by_app_and_secure_key`;

  const downloadRoot = path.join(root, 'downloaded');
  const parseRoot = path.join(root, 'parsed');
  const splitRoot = path.join(root, 'split');
  const mergeRoot = path.join(root, 'merged');

  if (steps.includes("download")) {
    log('downloading');
    ensureDirSync(downloadRoot);
    const cmd = `aws s3 cp s3://${bucket}/${s3Prefix}/ ${downloadRoot}/ --recursive --exclude "*" --include "*.parquet"`;
    execSync(cmd, { stdio: 'inherit' });
  }

  if (steps.includes("parse")) {
    log('parsing');
    ensureDirSync(parseRoot);
    const parquetFiles = glob.sync(`${downloadRoot}/**/*.parquet`);
    for (const [i, file] of parquetFiles.entries()) {
      log(`Parsing file ${i + 1}/${parquetFiles.length}: ${file}`);
      const jsonPath = path.join(parseRoot, path.basename(file, '.parquet') + '.json');
      const query = `COPY (SELECT * FROM read_parquet('${file.replace(/\\/g, '/')}')) TO '${jsonPath.replace(/\\/g, '/')}' (FORMAT JSON);`;
      execSync(`duckdb -c "${query}"`, { stdio: 'inherit' });
    }
  }

  if (steps.includes("split")) {
    log('spliting');
    await splitJson(parseRoot, splitRoot, year, month, log);
  }

  if (steps.includes("merge")) {
    log('merging');
    await mergeSplitJsonToParquet(splitRoot, mergeRoot, year, month, day, log);
  }

  if (steps.includes("upload")) {
    const command = `aws s3 cp . "s3://${bucket}/${uploadPrefix}" --recursive --exclude "*" --include "*.parquet"`;
    log(`upload from ${mergeRoot} using ${command}`);
    execSync(command, { cwd: mergeRoot, stdio: 'inherit' });
  }

  if (steps.includes("clean")) {
    log('clean');
    cleanFolders(root);
  }
})();

function ensureDirSync(dir) {
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
}

function cleanFolders(rootFolder) {
  if (fs.existsSync(rootFolder)) {
    fs.rmSync(rootFolder, { recursive: true, force: true });
  }
}

function sanitize(value) {
  return (value || nullValuePlaceholder).replace(/[^a-zA-Z0-9_-]/g, '_');
}

async function splitJson(parseRoot, splitRoot, year, month, log) {
  const files = glob.sync(`${parseRoot}/*.json`);
  for (const [i, file] of files.entries()) {
    log(`Splitting file ${i + 1}/${files.length}: ${file}`);

    const fileStream = fs.createReadStream(file);
    const rl = readline.createInterface({
      input: fileStream,
      crlfDelay: Infinity,
    });

    for await (const line of rl) {
      if (!line.trim()) continue;

      try {
        const record = JSON.parse(line);
        const secureKey = sanitize((record.run_remote_endpoint || "").split("/").pop());
        const application = sanitize(record.application);
        const outDir = path.join(splitRoot, application, year, month, secureKey);
        ensureDirSync(outDir);
        const outPath = path.join(outDir, path.basename(file, '.json') + '.jsonl');
        fs.appendFileSync(outPath, line + '\n');
      } catch (err) {
        console.error(`Error parsing line in file ${file}:`, err);
      }
    }
  }
}

async function mergeSplitJsonToParquet(splitRoot, mergeRoot, year, month, day, log) {
  const endpointDirs = glob.sync(`${splitRoot}/*/*/*/*`);
  let count = 0;

  for (const dir of endpointDirs) {
    let jsonlFiles = glob.sync(`${dir}/*.jsonl`);
    jsonlFiles = jsonlFiles.sort();
    if (jsonlFiles.length === 0) continue;

    const mergedJsonlPath = path.join(dir, '_merged.jsonl');
    const writeStream = fs.createWriteStream(mergedJsonlPath, { flags: 'w' });
    log(`Creating empty merged JSONL file: ${mergedJsonlPath}`);

    for (const jsonlFile of jsonlFiles) {
      log(`Appending ${jsonlFile} to ${mergedJsonlPath}`);
      const fileStream = fs.createReadStream(jsonlFile);
      const rl = readline.createInterface({ input: fileStream, crlfDelay: Infinity });

      for await (const line of rl) {
        if (line.trim()) {
          writeStream.write(line + '\n');
        }
      }
    }

    await new Promise((resolve) => writeStream.end(resolve));

    const parts = dir.split(path.sep);
    const secureKey = parts.pop();
    const _month = parts.pop();
    const _year = parts.pop();
    const application = parts.pop();
    const outDir = path.join(mergeRoot, application, year, month, secureKey);
    ensureDirSync(outDir);

    let writer = null;
    let partIndex = 0;
    let currentSize = 0;
    const maxSize = 500 * 1024 * 1024; // 500 MB

    const mergedFileStream = fs.createReadStream(mergedJsonlPath);
    const mergedRl = readline.createInterface({ input: mergedFileStream, crlfDelay: Infinity });

    for await (const line of mergedRl) {
      if (!line.trim()) continue;

      if (!writer) {
        const outPath = path.join(outDir, `${day}_${partIndex}.parquet`);
        log(`Creating new parquet file: ${outPath}`);
        writer = await parquet.ParquetWriter.openFile(staticSchema, outPath);
        currentSize = 0;
      }

      const original = JSON.parse(line);
      const cleaned = {};
      for (const key in staticSchema.fields) {
        const val = original[key];
        cleaned[key] = val == null ? '' : val;
      }

      await writer.appendRow(cleaned);
      currentSize += Buffer.byteLength(line, 'utf8');

      if (currentSize >= maxSize) {
        await writer.close();
        partIndex++;
        writer = null;
      }
    }

    if (writer) {
      await writer.close();
    }

    log(`Deleting merged JSONL file: ${mergedJsonlPath}`);
    fs.unlinkSync(mergedJsonlPath);
    count++;
  }

  return count;
}