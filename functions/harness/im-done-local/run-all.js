// Run every scenario in sequence against a running emulator + stub portal and
// print a pass/fail summary. Seed once (node seed.js) first.

const { execFileSync } = require("child_process");
const { SCENARIOS } = require("./scenarios");

const results = [];
for (const name of Object.keys(SCENARIOS)) {
  let passed = true;
  try {
    execFileSync("node", [`${__dirname}/run.js`, name], { stdio: "inherit" });
  } catch {
    passed = false;
  }
  results.push({ name, passed });
}

console.log("\n=== summary ===");
for (const { name, passed } of results) {
  console.log(`${passed ? "PASS ✓" : "FAIL ✗"}  ${name}`);
}
const failed = results.filter((r) => !r.passed).length;
console.log(`\n${results.length - failed}/${results.length} scenarios passed`);
process.exit(failed ? 1 : 0);
