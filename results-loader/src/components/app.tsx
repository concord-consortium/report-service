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
  const [portalAccessTokenStatus, setPortalAccessTokenStatus] = useState("");
  const [portalAccessToken, setPortalAccessToken] = useState("");

  const firebaseAppName = "token-service";
  const [firebaseJwtStatus, setFirebaseJwtStatus] = useState("");
  const [firebaseJwt, setFirebaseJwt] = useState("");

  const tokenServiceEnv = "staging";
  const [resourcesStatus, setResourcesStatus] = useState("");
  const [resources, setResources] = useState({} as ResourceMap);
  const [currentResource, setCurrentResource] = useState<Resource | undefined>();
  const resourceType = "athenaWorkgroup";

  const [credentialsStatus, setCredentialsStatus] = useState("");
  const [credentials, setCredentials] = useState<Credentials | undefined>();

  useEffect(() => {
    setPortalAccessTokenStatus("Authorizing in Portal...");
    const portalAccessTokenReturn = readPortalAccessToken(portalUrl, oauthClientName);
    if (portalAccessTokenReturn.accessToken) {
      setPortalAccessToken(portalAccessTokenReturn.accessToken);
    } else if (portalAccessTokenReturn.error) {
      setPortalAccessTokenStatus(portalAccessTokenReturn.error);
    }
  }, []);

  useEffect(() => {
    if (portalAccessToken) {
      setFirebaseJwtStatus("Getting Firebase JWT...");
      getFirebaseJwt(portalUrl, portalAccessToken, firebaseAppName).then(token => setFirebaseJwt(token));
    }
  }, [portalAccessToken]);

  useEffect(() => {
    const handleListMyResources = async () => {
      setResourcesStatus("Loading resources...");
      const resourceList = await listResources(firebaseJwt, true, tokenServiceEnv, resourceType as ResourceType);
      if(resourceList.length === 0) {
        setResourcesStatus("No resources found");
      } else {
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
      setCredentialsStatus("Loading credentials...");
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
        { portalAccessToken
          ? <div className="info">{`Portal Access Token: ${portalAccessToken}`}</div>
          : <div>{portalAccessTokenStatus}</div>
        }
        { firebaseJwt
          ? <div className="info">{`Firebase JWT: ${firebaseJwt.slice(0, 40)}...`}</div>
          : <div>{firebaseJwtStatus}</div>
        }
        { Object.keys(resources).length > 0 &&
          <div className="info">
            {Object.keys(resources).length} Athena workgroup resource{Object.keys(resources).length > 1 ? "s" : ""} found
          </div>
        }
        { currentResource
          ? <div className="info">Athena workgroup current resource:
              <div className="sub-info">id: {currentResource.id}</div>
              <div className="sub-info">name: {currentResource.name}</div>
              <div className="sub-info">description: {currentResource.description}</div>
            </div>
          : <div>{resourcesStatus}</div>
        }
        { credentials
          ? <div className="info">Athena workgroup current resource credentials:
              <div className="sub-info">access key id: {credentials.accessKeyId}</div>
              <div className="sub-info">secret access key: {credentials.secretAccessKey}</div>
              <div className="sub-info">session token: ${credentials.sessionToken.slice(0, 40)}...</div>
            </div>
          : <div>{credentialsStatus}</div>
        }
      </div>
    </div>
  );
};
