import React, { useState, useEffect } from "react";
import * as AWS from "aws-sdk";
import AmazonS3URI from "amazon-s3-uri";
import { Resource, Credentials, AthenaResource } from "@concord-consortium/token-service";
import dateFormat from "dateformat";
import "./query-item.scss";

interface IProps {
  queryExecutionId: string;
  credentials: Credentials;
  currentResource: Resource;
}

const formatDate = ( args: {time: Date|null|undefined, defaultString: string} ) => {
  const { time, defaultString } = args;
  if (!time) {
    return defaultString || "";
  }
  return dateFormat(time, "yyyy-mm-dd (dddd) ⎯ h:MM:ss tt Z");
};

export const QueryItem: React.FC<IProps> = (props) => {
  const { queryExecutionId, credentials, currentResource } = props;
  const [queryExecutionStatus, setQueryExecutionStatus] = useState("Loading query information...");
  const [resourceName, setResourceName] = useState("");
  const [resourceType, setResourceType] = useState("");
  const [submissionDateTime, setSubmissionDateTime] = useState("");
  const [queryCompletionStatus, setQueryCompletionStatus] = useState("");
  const [outputLocationBucket, setOutputLocationBucket] = useState("");
  const [outputLocationKey, setOutputLocationKey] = useState("");
  const [outputLocationRegion, setOutputLocationRegion] = useState("");
  const [downloadURLStatus, setDownloadURLStatus] = useState("");
  const [downloadURL, setDownloadURL] = useState("");

  // Poll every 5 seconds for updates on jobs that haven't succeeded or failed yet:
  useEffect(() => {
    const { region } = currentResource as AthenaResource;
    const { accessKeyId, secretAccessKey, sessionToken } = credentials;
    const athena = new AWS.Athena({ region, accessKeyId, secretAccessKey, sessionToken });
    const pollingInterval = 5 * 1000; // how frequently to check on queries.
    async function checkStatus() {
      const results = await athena.getQueryExecution({
        QueryExecutionId: queryExecutionId
      }).promise();
      setQueryCompletionStatus(results.QueryExecution?.Status?.State || "unknown");
    }
    const queryDone = queryCompletionStatus === "succeeded" || queryCompletionStatus === "failed";
    if(!queryDone) {
      const id = setInterval(checkStatus, pollingInterval);
      return () => {
        clearInterval(id);
      };
    }
  }, [queryCompletionStatus, queryExecutionId, currentResource, credentials]);

  useEffect(() => {
    const handleGetQueryExecution = async () => {
      const { region } = currentResource as AthenaResource;
      const { accessKeyId, secretAccessKey, sessionToken } = credentials;

      const athena = new AWS.Athena({ region, accessKeyId, secretAccessKey, sessionToken });
      const results = await athena.getQueryExecution({
        QueryExecutionId: queryExecutionId
      }).promise();

      const query = results.QueryExecution?.Query;
      const nameLoc = query?.search("-- name");
      const typeLoc = query?.search("-- type");
      if (nameLoc !== undefined && nameLoc >= 0) {
        const nameStartStr = query?.substring(nameLoc + 8);
        const _resourceName = nameStartStr?.substring(0, nameStartStr.search(/\n/));
        _resourceName && setResourceName(_resourceName);
      }
      if (typeLoc !== undefined && typeLoc >= 0) {
        const typeStartStr = query?.substring(typeLoc + 8);
        const _resourceType = typeStartStr?.substring(0, typeStartStr.search(/\n/));
        _resourceType && setResourceType(_resourceType);
      }

      setSubmissionDateTime(
        formatDate({
          time: (results.QueryExecution?.Status?.SubmissionDateTime),
          defaultString: "Error getting query submission date and time"
        })
      );
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

  const lowerQueryCompletionStatus = queryCompletionStatus.toLowerCase();
  const running = lowerQueryCompletionStatus === "running";
  const succeeded = lowerQueryCompletionStatus === "succeeded";
  const completionStatusSuffix = running ? "... (please wait)" : "";

  // show the generate button until it succeeds and it is clicked
  // the button will be disabled until it succeeds
  const showGenerateCSVLinkButton = !succeeded || !downloadURL;

  return (
    <div className="query-item">
      { queryExecutionStatus
        ? queryExecutionStatus
        : <div className="info-container">
            {resourceName && <div className="item-info">{`Name: ${resourceName}`}</div>}
            {resourceType && <div className="item-info">{`Type: ${resourceType}`}</div>}
            <div className="item-info">{`Creation date: ${submissionDateTime}`}</div>
            <div className="item-info">Completion status: <span className={lowerQueryCompletionStatus}>${lowerQueryCompletionStatus}${completionStatusSuffix}</span></div>
            { showGenerateCSVLinkButton
              ? <button onClick={handleGetSignedDownloadLink} disabled={!succeeded}>Generate CSV Download Link</button>
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
