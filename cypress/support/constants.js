// import { uid } from 'uid';

const config = Cypress.config();
console.log("config : " + config);

const constants = {
    // Base URLs for the learn-portal, the learn-report, and the report-server
    LEARN_PORTAL_BASE_URL  : config.learnPortalBaseUrl,
    LEARN_REPORT_BASE_URL  : config.learnReportBaseUrl,
    REPORT_SERVER_BASE_URL : config.reportServerBaseUrl,
    // researcher user details
    // RESEARCHER_USERNAME : config.researcher.username,
    RESEARCHER_PASSWORD : Cypress.env('password'),

    // UID : uid()
};
  
export default constants;
  