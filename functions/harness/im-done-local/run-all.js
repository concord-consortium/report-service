// Run every scenario in sequence against a running emulator + stub portal and
// print a pass/fail summary. Seed once (node seed.js) first. Direct-step scenarios
// go through run-step.js, which needs only the stub but does need a prior build.

const { execFileSync } = require("child_process");
const { SCENARIOS } = require("./scenarios");

const results = [];
for (const [name, scenario] of Object.entries(SCENARIOS)) {
  const driver = scenario.driver === "run-step" ? "run-step.js" : "run.js";
  let passed = true;
  try {
    execFileSync("node", [`${__dirname}/${driver}`, name], { stdio: "inherit" });
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
