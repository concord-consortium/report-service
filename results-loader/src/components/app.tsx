import React, { useState, useEffect } from "react";
import { Header } from "./header";
import { readPortalAccessToken, getFirebaseJwt } from "../utils/results-utils";

import "./app.scss";

export const App = () => {
  // const tokenServiceEnv = "staging";
  // const resourceType = "s3Folder";

  const portalUrl = "https://learn.staging.concord.org";
  const oauthClientName = "athena-results-loader";
  const [portalAccessToken, setPortalAccessToken] = useState("");
  const [portalAccessTokenError, setPortalAccessTokenError] = useState("");

  const firebaseAppName = "token-service";
  const [firebaseJwt, setFirebaseJwt] = useState("");


  useEffect(() => {
    const portalAccessTokenReturn = readPortalAccessToken(portalUrl, oauthClientName);
    if (portalAccessTokenReturn.accessToken) {
      setPortalAccessToken(portalAccessTokenReturn.accessToken);
    } else if (portalAccessTokenReturn.error) {
      setPortalAccessTokenError(portalAccessTokenReturn.error);
    }
  }, []);

  useEffect(() => {
    if (portalAccessToken) {
      getFirebaseJwt(portalUrl, portalAccessToken, firebaseAppName).then(token => setFirebaseJwt(token));
    }
  }, [portalAccessToken]);

  return (
    <div className="app">
      <Header />
      <div className="content">
        { !portalAccessToken
          ? portalAccessTokenError ? `Portal Error: ${portalAccessTokenError}` : "Authorizing in Portal..."
          : <>
              <div className="info">{`Portal Access Token: ${portalAccessToken}`}</div>
              { !firebaseJwt
                ? "Getting Firebase JWT..."
                : <div className="info">{`Firebase JWT: ${firebaseJwt.slice(0, 40)}...`}</div>
              }
            </>
        }
      </div>
    </div>
  );
};
