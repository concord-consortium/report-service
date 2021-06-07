import React, { useState, useEffect } from "react";
import { Header } from "./header";
import { readPortalAccessToken } from "../utils/results-utils";

import "./app.scss";

export const App = () => {
  // const tokenServiceEnv = "staging";
  const portalUrl = "https://learn.staging.concord.org";
  const oauthClientName = "athena-results-loader";
  const [portalAccessToken, setPortalAccessToken] = useState("");

  useEffect(() => {
    setPortalAccessToken(readPortalAccessToken(portalUrl, oauthClientName));
  }, []);

  return (
    <div className="app">
      <Header />
      <div className="content">
        { !portalAccessToken
          ? "Authorizing in Portal..."
          : `Portal Access Token: ${portalAccessToken}`
        }
      </div>
    </div>
  );
};
