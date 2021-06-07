import ClientOAuth2 from "client-oauth2";

const PORTAL_AUTH_PATH = "/auth/oauth_authorize";

const getURLParam = (name: string) => {
  const url = (self || window).location.href;
  name = name.replace(/[[]]/g, "\\$&");
  const regex = new RegExp(`[#?&]${name}(=([^&#]*)|&|#|$)`);
  const results = regex.exec(url);
  if (!results) return null;
  return decodeURIComponent(results[2].replace(/\+/g, " "));
};

export const authorizeInPortal = (portalUrl: string, oauthClientName: string) => {
  const portalAuth = new ClientOAuth2({
    clientId: oauthClientName,
    redirectUri: window.location.origin + window.location.pathname + window.location.search,
    authorizationUri: `${portalUrl}${PORTAL_AUTH_PATH}`
  });
  // Redirect
  window.location.href = portalAuth.token.getUri();
};

export const readPortalAccessToken = (portalUrl: string, oauthClientName: string): string => {
  // TODO: add error handling
  // from PR: some error condition happens in the portal and it redirects back to the client with an error message.
  // This error redirect can happen here:
  // https://github.com/concord-consortium/rigse/blob/917d5aaa788502b00fe906749af80275203b83fd/rails/app/controllers/auth_controller.rb#L45-L47
  // The invalid response can happen for these 2 reasons:
  // https://github.com/concord-consortium/rigse/blob/917d5aaa788502b00fe906749af80275203b83fd/rails/app/models/access_grant.rb#L65-L74
  // Basically if the client is not configured correctly in the portal. Or the request from the client uses an invalid response type.
  // The response type is handled by the ClientOAuth2 library so hopefully that would never be a problem. But if the client is not configured with the
  // 'public' type then the portal should redirect back to the client with a error url param.
  const accessToken = getURLParam("access_token");
  if (!accessToken) {
    authorizeInPortal(portalUrl, oauthClientName);
  } else {
    // c.f. https://stackoverflow.com/questions/22753052/remove-url-parameters-without-refreshing-page
    if (window.history?.pushState !== undefined) {
      // if pushstate exists, add a new state to the history, this changes the url without reloading the page
      window.history.pushState({}, document.title, window.location.pathname);
    }
  }
  return accessToken || "";
};

export const getFirebaseJwt = (portalUrl: string, portalAccessToken: string, firebaseAppName: string): Promise<string> => {
  const authHeader = { Authorization: `Bearer ${portalAccessToken}` };
  const firebaseTokenGettingUrl = `${portalUrl}/api/v1/jwt/firebase?firebase_app=${firebaseAppName}`;
  return fetch(firebaseTokenGettingUrl, { headers: authHeader })
    .then(response => response.json())
    .then(json => json.token);
};
