const fs = require("fs");
const path = require("path");
const { AthenaClient, GetQueryExecutionCommand, ListQueryExecutionsCommand } = require("@aws-sdk/client-athena");
const { parse } = require("json2csv");

async function getAllAthenaQueries() {
  const client = new AthenaClient({ region: "us-east-1" }); // Replace with your AWS region

  try {
    // Replace with your workgroup name
    const workgroupName = "scytacki-concord-org-cvmQK4PvbL7Ccxey3px7";

    // List query executions (you may need to implement pagination if there are many queries)
    const listQueryExecutionsCommand = new ListQueryExecutionsCommand({ WorkGroup: workgroupName });
    const listQueryExecutionsResponse = await client.send(listQueryExecutionsCommand);

    if (listQueryExecutionsResponse.QueryExecutionIds.length === 0) {
      console.log("No queries found in the workgroup.");
      return;
    }

    const queryExecutions = [];

    for (const queryExecutionId of listQueryExecutionsResponse.QueryExecutionIds) {
      const getQueryExecutionCommand = new GetQueryExecutionCommand({ QueryExecutionId: queryExecutionId });
      const getQueryExecutionResponse = await client.send(getQueryExecutionCommand);
      queryExecutions.push(getQueryExecutionResponse.QueryExecution);
    }

    // Write JSON file
    const jsonFilePath = path.join(__dirname, "query_executions.json");
    fs.writeFileSync(jsonFilePath, JSON.stringify({ QueryExecutions: queryExecutions }, null, 2));
    console.log(`JSON file written to ${jsonFilePath}`);

    // Prepare CSV data
    const fields = [
      "QueryExecutionId",
      "WorkGroup",
      "Status.State",
      "Status.CompletionDateTime",
      "Status.SubmissionDateTime",
      "Statistics.DataScannedInBytes",
    ];

    const csvData = queryExecutions.map((execution) => ({
      QueryExecutionId: execution.QueryExecutionId,
      WorkGroup: execution.WorkGroup,
      "Status.State": execution.Status?.State,
      "Status.CompletionDateTime": execution.Status?.CompletionDateTime,
      "Status.SubmissionDateTime": execution.Status?.SubmissionDateTime,
      "Statistics.DataScannedInBytes": execution.Statistics?.DataScannedInBytes,
    }));

    const csv = parse(csvData, { fields });

    // Write CSV file
    const csvFilePath = path.join(__dirname, "query_executions.csv");
    fs.writeFileSync(csvFilePath, csv);
    console.log(`CSV file written to ${csvFilePath}`);
  } catch (error) {
    console.error("Error fetching Athena query details:", error);
  }
}

getAllAthenaQueries();