import * as c from '../../support/constants.js'
import LearnPortalHomePage           from "../../support/pages/learn_portal/home_page.js";
import LearnPortalGettingStartedPage from "../../support/pages/learn_portal/getting_started_page.js";
import LearnPortalAdminPage          from "../../support/pages/learn_portal/admin_page.js";
import LearnReportLoginPage          from "../../support/pages/learn_report/login_page.js";
import LearnReportReportLearnerPage  from "../../support/pages/learn_report/report_learner_page.js";

// const sp lpsp;
// let sp = new lpsp;

// const 

// let sp = new lpsp;

let homePage           = new LearnPortalHomePage(),
    gettingStartedPage = new LearnPortalGettingStartedPage(),
    adminPage          = new LearnPortalAdminPage(),
    loginPage          = new LearnReportLoginPage,
    reportLearnerPage  = new LearnReportReportLearnerPage;

context("Researcher progresses from Start page to Admin page, in the Learn Portal; "
        +"then to a Learn-Report page; and finally to a Report-Server page", () => {

    before(function() {
        // TODO: this may not be needed here
    });

    after(function() {
        cy.clearAllCookies();
    });

    it("Progress from the Learn Portal's Home page, through other pages, to the Learn Report's Report Learner page", () => {
        // cy.visit(c.LEARN_PORTAL_BASE_URL); // Visit LEARN Portal home page
        cy.visit('https://learn.portal.staging.concord.org'); // Visit LEARN Portal home page

        homePage.login('researcher', 'password');

        gettingStartedPage.verifyLogoutButtonIsVisible();
        // cy.get('a[title="Log Out"]').should('be.visible');
        gettingStartedPage.clickAdminLink();

        adminPage.clickLearnerReportsLink();

        loginPage.login('researcher', 'password');

        reportLearnerPage.showDetailsReport('Concord Consortium', 'Doug Martin', 'Test Glossary Reports');
    });

    it("Test the Report Server's 'Your Reports' page separately", () => {
        // cy.visit('https://report-server.concordqa.org/reports?portal=https%3A%2F%2Flearn-report.portal.staging.concord.org');
        cy.visit('https://report-server.concordqa.org/reports');

        // TODO: testing of this page
    })


});
