/**
 * This file models the learn-report login page, that is, in production, the one with this URL:
 *     https://learn-report.concord.org/auth/login
 * or on staging:
 *     https://learn-report.portal.staging.concord.org/auth/login
 * 
 * Note: this is currently far from complete, but may grow as needed for additional tests.
 */

const lpe = {    // (learn-report) login page elements
    USERNAME_INPUT:  'input[id="username"]',
    PASSWORD_INPUT:  'input[id="password"]',
    LOGIN_BUTTON:    'input[id="submit"]',
    SCHOOLOGY_LOGIN: 'a[id="schoology_login_button"]',
    GOOGLE_LOGIN:    'a[id="google_login_button"]',
}

class LearnReportLoginPage {

    // Utility method, used below
    verifyElementIsVisible(selector, text='') {
        cy.get(selector).should('contain', text).and('be.visible');
    }

    /**
     * Sign in using the 'Schoology' or 'Google' button, or by specifying the username & password.
     * @param {string} login may be 'Google (default) or 'Schoology' (case insensitive); otherwise, specifies the username
     * @param {string} password must be specified, if sign_in is not 'Google' or 'Schoology'
     */
    login(login='google', password=null) {

        if (login.toLowerCase() == 'google') {
            this.verifyElementIsVisible(lpe.GOOGLE_LOGIN, 'Google');
            cy.get(lpe.GOOGLE_LOGIN).click({force: true});

        } else if (login.toLowerCase() == 'schoology') {
            this.verifyElementIsVisible(lpe.SCHOOLOGY_LOGIN, 'Schoology');
            cy.get(lpe.SCHOOLOGY_LOGIN).click({force: true});

        } else if (password==null) {
            throw new Error("The 'password' parameter cannot be null when a username is given, "
                +"as opposed to when a 'Google' or Schoology' login is used.");

        } else {
            this.verifyElementIsVisible(lpe.USERNAME_INPUT);
            this.verifyElementIsVisible(lpe.PASSWORD_INPUT);
            cy.get(lpe.USERNAME_INPUT).type(login);
            cy.get(lpe.PASSWORD_INPUT).type(password);

            this.verifyElementIsVisible(lpe.LOGIN_BUTTON);
            cy.get(lpe.LOGIN_BUTTON).click({force: true});
        }
    }
}

export default LearnReportLoginPage;
