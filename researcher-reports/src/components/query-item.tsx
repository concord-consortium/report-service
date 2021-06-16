import React, { useState, useEffect } from "react";
import * as AWS from "aws-sdk";
import AmazonS3URI from "amazon-s3-uri";
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
  const [queryCompletionStatus, setQueryCompletionStatus] = useState("");
  const [outputLocationBucket, setOutputLocationBucket] = useState("");
  const [outputLocationKey, setOutputLocationKey] = useState("");
  const [outputLocationRegion, setOutputLocationRegion] = useState("");
  const [downloadURLStatus, setDownloadURLStatus] = useState("");
  const [downloadURL, setDownloadURL] = useState("");

  useEffect(() => {
    const handleGetQueryExecution = async () => {
      const { region } = currentResource as AthenaResource;
      const { accessKeyId, secretAccessKey, sessionToken } = credentials;
      const athena = new AWS.Athena({ region, accessKeyId, secretAccessKey, sessionToken });

      const results = await athena.getQueryExecution({
        QueryExecutionId: queryExecutionId
      }).promise();

      setSubmissionDateTime(results.QueryExecution?.Status?.SubmissionDateTime?.toUTCString()
       || "Error getting query submission date and time");
      setQueryCompletionStatus(results.QueryExecution?.Status?.State || "unknown");

      const outputLocation = results.QueryExecution?.ResultConfiguration?.OutputLocation;

      // get and store information needed to create signed URL
      if (outputLocation) {
        const URIinfo = AmazonS3URI(outputLocation);
        if (URIinfo.bucket && URIinfo.key && URIinfo.region) {
          setOutputLocationBucket(URIinfo.bucket);
          setOutputLocationKey(URIinfo.key);
          setOutputLocationRegion(URIinfo.region);
          setQueryExecutionStatus("");
        } else {
          setQueryExecutionStatus("Error getting query output location URI info");
        }
      } else {
        setQueryExecutionStatus("Error getting query output location");
      }
    };

    handleGetQueryExecution();
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  const handleGetSignedDownloadLink = () => {
    setDownloadURLStatus("Generating download URL...");
    const myConfig = new AWS.Config({
      credentials, region: outputLocationRegion
    });
    const s3 = new AWS.S3(myConfig);
    const signedUrlExpireSeconds = 60 * 10; // 10 minutes
    const url = s3.getSignedUrl("getObject", {
      Bucket: outputLocationBucket,
      Key: outputLocationKey,
      Expires: signedUrlExpireSeconds
    });
    if (url) {
      setDownloadURL(url);
      setDownloadURLStatus("");
    } else {
      setDownloadURLStatus("Error generating download URL...");
    }
  };

  return (
    <div className="query-item">
      { queryExecutionStatus
        ? queryExecutionStatus
        : <div className="info-container">
            <div className="item-info">{`Creation date: ${submissionDateTime}`}</div>
            <div className="item-info">{`Completion status: ${queryCompletionStatus.toLowerCase()}`}</div>
            { !downloadURL
              ? <button onClick={handleGetSignedDownloadLink}>Generate CSV Download Link</button>
              : <>
                  <div className="item-info">Download CSV (link valid for 10 minutes):</div>
                  { downloadURLStatus
                    ? <div className="item-info">{downloadURLStatus}</div>
                    : <div className="item-info"><a href={downloadURL}>{downloadURL}</a></div>
                  }
                </>
            }
          </div>
      }
    </div>
  );
};
