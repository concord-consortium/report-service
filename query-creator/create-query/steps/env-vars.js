exports.validate = () => {

  const missingVar = (name) => {
    throw new Error(`Missing required ${name} environment variable`);
  }

  if (!process.env.OUTPUT_BUCKET) {
    missingVar("OUTPUT_BUCKET");
  }
  if (!process.env.REPORT_SERVICE_TOKEN) {
    missingVar("REPORT_SERVICE_TOKEN");
  }
  if (!process.env.REPORT_SERVICE_URL) {
    missingVar("REPORT_SERVICE_URL");
  }
}