/**
 * This file models the learn-portal getting started page, that is, in production, the one with this URL:
 *     https://learn.concord.org/getting_started
 * or on staging:
 *     https://learn.portal.staging.concord.org/getting_started
 * 
 * Note: this is currently far from complete, but may grow as needed for additional tests.
 */

const gspe = {    // (learn portal) getting started page elements
    LOGOUT_BUTTON: 'a[title="Log Out"]',
    ADMIN_LINK:    'a[href="/admin"]',
}

class LearnPortalGettingStartedPage {

    // Utility method, used below
    verifyElementIsVisible(selector, text='') {
        cy.get(selector).should('contain', text).and('be.visible');
    }

    verifyLogoutButtonIsVisible() {
        this.verifyElementIsVisible(gspe.LOGOUT_BUTTON, 'Log Out');
    }

    clickAdminLink() {
        cy.get(gspe.ADMIN_LINK).click();
    }
}

export default LearnPortalGettingStartedPage;
