/**
 * This file models the learn-portal admin page, that is, in production, the one with this URL:
 *     https://learn.concord.org/admin
 * or on staging:
 *     https://learn.portal.staging.concord.org/admin
 * 
 * Note: this is currently far from complete, but may grow as needed for additional tests.
 */

const ADMIN_LINKS = 'div[class="admin-links-cols"]'

const ape = {    // (learn portal) admin page elements
    LEARNER_REPORTS_LINK: ADMIN_LINKS+' a[contains="Learner Reports"]',
    USER_REPORTS_LINK:    ADMIN_LINKS+' a[contains="User Reports"]',
}

class LearnPortalAdminPage {

    // Utility method, used below
    verifyElementIsVisible(selector, text='') {
        cy.get(selector).should('contain', text).and('be.visible');
    }

    clickLearnerReportsLink() {
        cy.get(ADMIN_LINKS).contains('Learner Reports').should('be.visible').then(($learnerReportsLink) => {
            // Remove target="_blank", so the link opens in the same tab
            $learnerReportsLink.attr('target', null);
        }).click();
    }

    clickUserReportsink() {
        this.verifyElementIsVisible(ape.USER_REPORTS_LINK);
        // Before clicking the link, remove target="_blank", so the link opens in the same tab
        cy.get(ape.USER_REPORTS_LINK).attr("target", null).click();
    }
}

export default LearnPortalAdminPage;
