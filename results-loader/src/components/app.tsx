import React, { useState, useEffect } from "react";
import { Resource, ResourceType, Credentials } from "@concord-consortium/token-service";
import { Header } from "./header";
import { readPortalAccessToken, getFirebaseJwt, listResources, getCredentials } from "../utils/results-utils";

import "./app.scss";

type ResourceMap = {[key: string]: Resource};

export const App = () => {
  // const tokenServiceEnv = "staging";
  // const resourceType = "s3Folder";

  const portalUrl = "https://learn.staging.concord.org";
  const oauthClientName = "athena-results-loader";
  const [portalAccessToken, setPortalAccessToken] = useState("");
  const [portalAccessTokenError, setPortalAccessTokenError] = useState("");

  const firebaseAppName = "token-service";
  const [firebaseJwt, setFirebaseJwt] = useState("");

  const tokenServiceEnv = "staging";
  const [resourcesStatus, setResourcesStatus] = useState("nothing happening...");
  const [resources, setResources] = useState({} as ResourceMap);
  const [currentResource, setCurrentResource] = useState<Resource | undefined>();
  const resourceType = "athenaWorkgroup";

  const [credentials, setCredentials] = useState<Credentials | undefined>();

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

  useEffect(() => {
    const handleListMyResources = async () => {
      // Clear existing resources
      setResources({} as ResourceMap);
      setResourcesStatus("loading...");
      const resourceList = await listResources(firebaseJwt, true, tokenServiceEnv, resourceType as ResourceType);
      if(resourceList.length === 0) {
        setResourcesStatus("no resources found");
      } else {
        setResourcesStatus("loaded");
        setResources(resourceList.reduce((map: ResourceMap, resource: Resource) => {
          map[resource.id] = resource;
          return map;
        }, {} as ResourceMap));
        setCurrentResource(resourceList[0]);
      }
    };

    if (portalAccessToken && firebaseJwt) {
      handleListMyResources();
    }
  }, [portalAccessToken, firebaseJwt]);

  useEffect(() => {
    const handleGetCredentials = async () => {
      if (!currentResource) return;
      const _credentials = await getCredentials({
        resource: currentResource,
        firebaseJwt,
        tokenServiceEnv
      });
      setCredentials(_credentials);
    };

    if (portalAccessToken && firebaseJwt && currentResource) {
      handleGetCredentials();
    }
  }, [portalAccessToken, firebaseJwt, currentResource]);

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
        { Object.keys(resources).length > 0 &&
          <div className="info">{Object.keys(resources).length} Athena workgroup resources found </div>
        }
        { currentResource
          ? <div className="info">Athena workgroup current resource:
              <div className="sub-info">id: {currentResource.id}</div>
              <div className="sub-info">name: {currentResource.name}</div>
              <div className="sub-info">description: {currentResource.description}</div>
            </div>
          : <div>{resourcesStatus}</div>
        }
        { credentials &&
          <div className="info">Athena workgroup current resource credentials:
            <div className="sub-info">access key id: {credentials.accessKeyId}</div>
            <div className="sub-info">secret access key: {credentials.secretAccessKey}</div>
            <div className="sub-info">session token: ${credentials.sessionToken.slice(0, 40)}...</div>
          </div>
        }
      </div>
    </div>
  );
};
