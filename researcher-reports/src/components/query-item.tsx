import React, { useState, useEffect } from "react";
import * as AWS from "aws-sdk";
import { Resource, Credentials, AthenaResource } from "@concord-consortium/token-service";

import "./query-item.scss";

interface IProps {
  queryExecutionId: string;
  credentials: Credentials;
  currentResource: Resource;
}

export const QueryItem: React.FC<IProps> = (props) => {
  const { queryExecutionId, credentials, currentResource } = props;
  const [queryExecutionStatus, setQueryExecutionStatus] = useState("Loading query information...");
  const [submissionDateTime, setSubmissionDateTime] = useState("");
  const [outputLocation, setOutputLocation] = useState("");

  useEffect(() => {
    const handleGetQueryExecution = async () => {
      const { region } = currentResource as AthenaResource;
      const { accessKeyId, secretAccessKey, sessionToken } = credentials;
      const athena = new AWS.Athena({ region, accessKeyId, secretAccessKey, sessionToken });

      const results = await athena.getQueryExecution({
        QueryExecutionId: queryExecutionId
      }).promise();

      setQueryExecutionStatus("");
      setSubmissionDateTime(results.QueryExecution?.Status?.SubmissionDateTime?.toUTCString() || "error");
      setOutputLocation(results.QueryExecution?.ResultConfiguration?.OutputLocation || "error");
    };

    handleGetQueryExecution();
  }, [credentials, currentResource, queryExecutionId]);

  return (
    <div className="query-item">
      { queryExecutionStatus
        ? queryExecutionStatus
        : <>
            <div>
              <div className="item-info">{`Creation date: ${submissionDateTime}`}</div>
              <div className="item-info">{`Output location: ${outputLocation}`}</div>
            </div>
            <button>Generate Download Link</button>
          </>
      }
    </div>
  );
};
