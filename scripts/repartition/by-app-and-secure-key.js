#!/usr/bin/env node

/*

  This is a one-off script to repartition the S3 parquet logs by application and secure key from
  their original time based partitioning.

  It ran at the end of May/start of June on a Linux LightSail instance with duckdb and the aws cli installed.
  The script ran on production for several days, and on staging for a few hours.

  The script was run in a screen session using the following bash script, with the extra
  `rm -rf ...` in case the script failed before the clean step and left behind data.

  NOTE: the 2014 log data (on both production and staging) only has March and April, so those months are hardcoded in the script.

  For production:

  node ./by-app-and-secure-key.js production 3 2014 2>>errors.txt
  node ./by-app-and-secure-key.js production 4 2014 2>>errors.txt
  for year in {2015..2024}; do
    for month in {1..12}; do
      node ./by-app-and-secure-key.js production $month $year 2>>errors.txt
      rm -rf downloaded parsed split merged
    done
  done
  for month in {1..5}; do
    node ./by-app-and-secure-key.js production $month 2025 2>>errors.txt
    rm -rf downloaded parsed split merged
  done

  For staging:

  - Run `export AWS_PROFILE=qa` (assuming you have a profile set up for the QA environment)
  - Update the script to use `qa` instead of `production` in the script above

  */

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');
const glob = require('glob');
const parquet = require('parquetjs');
const { Command } = require('commander');
const readline = require('readline');

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

const program = new Command();
program
  .name('s3-parquet-processor')
  .description('Download, parse, merge, upload, and clean S3 parquet logs')
  .argument('<environment>', 'production or qa')
  .argument('<month>', 'Month as 1 or 2 digit number')
  .argument('<year>', 'Year as 4 digit number')
  .option('-s, --step <step...>', 'Steps to execute (download, parse, split, merge, upload, clean)', ['all'])
  .action(async (env, monthArg, yearArg, options) => {
    if (!['production', 'qa'].includes(env)) {
      console.error('Invalid environment. Use "production" or "qa".');
      process.exit(1);
    }
    if (!/^\d{1,2}$/.test(monthArg) || !/^\d{4}$/.test(yearArg)) {
      console.error('Invalid month or year format. Month should be 1 or 2 digits, year should be 4 digits.');
      process.exit(1);
    }
    const monthArgNum = parseInt(monthArg, 10);
    if (monthArgNum < 1 || monthArgNum > 12) {
      console.error('Month must be between 1 and 12.');
      process.exit(1);
    }
    const numericYearArg = parseInt(yearArg, 10);
    if (numericYearArg < 2000 || numericYearArg > new Date().getFullYear()) {
      console.error('Year must be between 2000 and the current year.');
      process.exit(1);
    }
    console.log(`Running in environment: ${env}`);
    console.log(`Processing logs for month: ${monthArg}, year: ${yearArg}`);
    console.log(`Steps to execute: ${options.step.length ? options.step.join(', ') : 'all'}`);

    const isProduction = env === 'production';
    const month = pad(monthArg);
    const year = yearArg;
    const steps = options.step.length ? options.step : ['all'];
    const runSteps = steps.includes('all') ? ['download', 'parse', 'split', 'merge', 'upload', 'clean'] : steps;

    const bucket =  isProduction ? 'log-ingester-production' : 'log-ingester-qa';
    const s3Prefix = `processed_logs_with_id/${year}/${month}`;
    const uploadPrefix = `logs_by_app_and_secure_key`;
    const downloadRoot = 'downloaded';
    const parseRoot = 'parsed';
    const splitRoot = 'split';
    const mergeRoot = 'merged';

    if (runSteps.includes('download')) {
      console.log('Starting step: download');
      ensureDirSync(downloadRoot);
      const cmd = `aws s3 cp s3://${bucket}/${s3Prefix}/ ${downloadRoot}/ --recursive --exclude "*" --include "*.parquet"`;
      execSync(cmd, { stdio: 'inherit' });
      const downloaded = glob.sync(`${downloadRoot}/**/*.parquet`).length;
      logStep('download', downloaded, year, month);
    }

    if (runSteps.includes('parse')) {
      console.log('Starting step: parse');
      ensureDirSync(parseRoot);
      const parquetFiles = glob.sync(`${downloadRoot}/**/*.parquet`);
      let count = 0;
      for (const [i, file] of parquetFiles.entries()) {
        console.log(`Parsing file ${i + 1}/${parquetFiles.length}: ${file}`);
        const jsonPath = path.join(parseRoot, path.basename(file, '.parquet') + '.json');
        const query = `COPY (SELECT * FROM read_parquet('${file.replace(/\\/g, '/')}')) TO '${jsonPath.replace(/\\/g, '/')}' (FORMAT JSON);`;
        execSync(`duckdb -c "${query}"`, { stdio: 'inherit' });
        count++;
      }
      logStep('parse', count, year, month);
    }

    if (runSteps.includes('split')) {
      console.log('Starting step: split');
      const count = await splitJson(parseRoot, splitRoot, year, month);
      logStep('split', count, year, month);
    }

    if (runSteps.includes('merge')) {
      console.log('Starting step: merge');
      const count = await mergeSplitJsonToParquet(splitRoot, mergeRoot, year, month);
      logStep('merge', count, year, month);
    }

    if (runSteps.includes('upload')) {
      console.log('Starting step: upload');
      const command = `aws s3 cp . "s3://${bucket}/${uploadPrefix}" --recursive --exclude "*" --include "*.parquet"`;
      console.log(`Running upload command from ${mergeRoot}: ${command}`);
      execSync(command, { cwd: mergeRoot, stdio: 'inherit' });

      const files = glob.sync(`${mergeRoot}/**/*.parquet`);
      logStep('upload', files.length, year, month);
    }

    if (runSteps.includes('clean')) {
      console.log('Starting step: clean');
      cleanFolders(downloadRoot, parseRoot, splitRoot, mergeRoot);
      logStep('clean', 0, year, month);
    }
  });

program.parse(process.argv);

function pad(num) {
  return num.toString().padStart(2, '0');
}

function ensureDirSync(dir) {
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
}

function logStep(stepName, fileCount, year, month) {
  const timestamp = new Date().toISOString();
  const message = `[${timestamp}] Completed step: ${stepName}, Files processed: ${fileCount}, Month: ${month}, Year: ${year}\n`;
  fs.appendFileSync('summary.log', message);
  console.log(message.trim());
}

function cleanFolders(...folders) {
  for (const folder of folders) {
    if (fs.existsSync(folder)) {
      fs.rmSync(folder, { recursive: true, force: true });
    }
  }
}

function sanitize(value) {
  return (value || nullValuePlaceholder).replace(/[^a-zA-Z0-9_-]/g, '_');
}

async function splitJson(parseRoot, splitRoot, year, month) {
  const files = glob.sync(`${parseRoot}/*.json`);
  for (const [i, file] of files.entries()) {
    console.log(`Splitting file ${i + 1}/${files.length}: ${file}`);

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

async function mergeSplitJsonToParquet(splitRoot, mergeRoot, year, month) {
  const endpointDirs = glob.sync(`${splitRoot}/*/*/*/*`);
  let count = 0;

  for (const dir of endpointDirs) {
    let jsonlFiles = glob.sync(`${dir}/*.jsonl`);
    jsonlFiles = jsonlFiles.sort();
    if (jsonlFiles.length === 0) continue;

    const mergedJsonlPath = path.join(dir, '_merged.jsonl');
    const writeStream = fs.createWriteStream(mergedJsonlPath, { flags: 'w' });

    for (const jsonlFile of jsonlFiles) {
      console.log(`Appending ${jsonlFile} to ${mergedJsonlPath}`);
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
    const application = parts[1];
    const secureKey = parts[4];
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
        const outPath = path.join(outDir, `merged_${partIndex}.parquet`);
        console.log(`Creating new parquet file: ${outPath}`);
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

    fs.unlinkSync(mergedJsonlPath);
    count++;
  }

  return count;
}