const fs = require("fs");
const path = require("path");
const { AthenaClient, GetQueryExecutionCommand, ListQueryExecutionsCommand, ListWorkGroupsCommand } = require("@aws-sdk/client-athena");
const { parse } = require("json2csv");

function formatBytes(bytes) {
  if (bytes === 0) return "0 Bytes";
  const sizes = ["Bytes", "KB", "MB", "GB", "TB"];
  const i = Math.floor(Math.log(bytes) / Math.log(1024));
  return parseFloat((bytes / Math.pow(1024, i)).toFixed(2)) + " " + sizes[i];
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function getAllAthenaQueries() {
  // Disable middleware logger to avoid accessing undefined properties
  const client = new AthenaClient({
    region: "us-east-1", // Replace with your AWS region
    maxAttempts: 7, // Set maximum retry attempts
  });

  try {
    // List all workgroups
    const listWorkGroupsCommand = new ListWorkGroupsCommand({ MaxResults: 50 });
    let listWorkGroupsResponse = await client.send(listWorkGroupsCommand);
    const allWorkGroups = listWorkGroupsResponse.WorkGroups;

    while (listWorkGroupsResponse.NextToken) {
      listWorkGroupsResponse = await client.send(
        new ListWorkGroupsCommand({ MaxResults: 50, NextToken: listWorkGroupsResponse.NextToken })
      );
      allWorkGroups.push(...listWorkGroupsResponse.WorkGroups);
    }

    if (allWorkGroups.length === 0) {
      console.log("No workgroups found.");
      return;
    }

    const queryExecutions = [];

    for (const workgroup of allWorkGroups) {
      const workgroupName = workgroup.Name;
      console.log(`Fetching queries for workgroup: ${workgroupName}`);

      // List query executions for the workgroup
      const listQueryExecutionsCommand = new ListQueryExecutionsCommand({ WorkGroup: workgroupName, MaxResults: 50 });
      let listQueryExecutionsResponse = await client.send(listQueryExecutionsCommand);
      const allQueryExecutionIds = listQueryExecutionsResponse.QueryExecutionIds || [];

      while (listQueryExecutionsResponse.NextToken) {
        listQueryExecutionsResponse = await client.send(
          new ListQueryExecutionsCommand({ WorkGroup: workgroupName, MaxResults: 50, NextToken: listQueryExecutionsResponse.NextToken })
        );
        allQueryExecutionIds.push(...(listQueryExecutionsResponse.QueryExecutionIds || []));
      }

      if (allQueryExecutionIds.length === 0) {
        console.log(`No query executions found for workgroup: ${workgroupName}`);
        continue;
      }

      console.log(`Found ${allQueryExecutionIds.length} query executions for workgroup: ${workgroupName}`);

      for (const queryExecutionId of allQueryExecutionIds) {
        const getQueryExecutionCommand = new GetQueryExecutionCommand({ QueryExecutionId: queryExecutionId });
        let getQueryExecutionResponse;

        try {
          getQueryExecutionResponse = await client.send(getQueryExecutionCommand);
        } catch (error) {
          if (error.name === "ThrottlingException") {
            console.log("ThrottlingException encountered. Retrying after a delay...");
            await sleep(2000); // Wait for 2 seconds before retrying
            getQueryExecutionResponse = await client.send(getQueryExecutionCommand);
          } else {
            throw error;
          }
        }

        queryExecutions.push(getQueryExecutionResponse.QueryExecution);
      }
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
      "Statistics.DataScannedHumanReadable",
    ];

    const csvData = queryExecutions.map((execution) => ({
      QueryExecutionId: execution.QueryExecutionId,
      WorkGroup: execution.WorkGroup,
      "Status.State": execution.Status?.State,
      "Status.CompletionDateTime": execution.Status?.CompletionDateTime,
      "Status.SubmissionDateTime": execution.Status?.SubmissionDateTime,
      "Statistics.DataScannedInBytes": execution.Statistics?.DataScannedInBytes,
      "Statistics.DataScannedHumanReadable": formatBytes(execution.Statistics?.DataScannedInBytes || 0),
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