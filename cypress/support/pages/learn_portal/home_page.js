/**
 * This file models the learn-portal home page, that is, in production, the one with this URL:
 *     https://learn.concord.org/
 * or on staging:
 *     https://learn.portal.staging.concord.org/
 * 
 * Note: this is currently far from complete, but may grow as needed for additional tests.
 */

// Used multiple times in the 'pfe' constants defined below
const LOGIN_DIALOG = 'div[class^="login-default-modal-content"]'

const hpe = {    // (learn portal) home page elements
    LOGIN_BUTTON:      'a[title="Log In"]',
    LOGIN_DIALOG:      LOGIN_DIALOG,
    GOOGLE_SIGN_IN:    LOGIN_DIALOG+' a[id="google"]',
    SCHOOLOGY_SIGN_IN: LOGIN_DIALOG+' a[id="schoology"]',
    USERNAME_INPUT:    LOGIN_DIALOG+' input[name="user[login]"]',
    PASSWORD_INPUT:    LOGIN_DIALOG+' input[name="user[password]"]',
    LOGIN_DIALOG_LOGIN_BUTTON: LOGIN_DIALOG+' button[class="submit-btn"]',
}

class LearnPortalHomePage {

    // Utility methods, used below
    verifyElementIsVisible(selector, text='') {
        cy.get(selector).should('contain', text).and('be.visible');
    }
    verifyElementDoesNotExist(selector) {
        cy.get(selector).should('not.exist');
    }

    verifyLoginButtonIsVisible() {
        this.verifyElementIsVisible(hpe.LOGIN_BUTTON, 'Log In');
    }
    verifyLoginDialogIsVisible() {
        // the text after this varies in Staging vs. Production
        this.verifyElementIsVisible(hpe.LOGIN_DIALOG, 'Log in to the')
    }

    /**
     * Sign in using the 'Google' or 'Schoology' button, or by specifying the username & password.
     * @param {string} sign_in may be 'Google (default) or 'Schoology' (case insensitive); otherwise, specifies the username
     * @param {string} password must be specified, if sign_in is not 'Google' or 'Schoology'
     */
    login(sign_in='google', password=null) {
        this.verifyLoginButtonIsVisible();
        cy.get(hpe.LOGIN_BUTTON).click({force: true});
        this.verifyLoginDialogIsVisible();

        if (sign_in.toLowerCase() == 'google') {
            this.verifyElementIsVisible(hpe.GOOGLE_SIGN_IN, 'Google');
            cy.get(hpe.GOOGLE_SIGN_IN).click({force: true});

        } else if (sign_in.toLowerCase() == 'schoology') {
            this.verifyElementIsVisible(hpe.SCHOOLOGY_SIGN_IN, 'Schoology');
            cy.get(hpe.SCHOOLOGY_SIGN_IN).click({force: true});

        } else if (password==null) {
            throw new Error("The 'password' parameter cannot be null when a username is given, "
                +"as opposed to when a 'Google' or Schoology' login is used.");

        } else {
            this.verifyElementIsVisible(hpe.USERNAME_INPUT);
            this.verifyElementIsVisible(hpe.PASSWORD_INPUT);
            cy.get(hpe.USERNAME_INPUT).type(sign_in);
            cy.get(hpe.PASSWORD_INPUT).type(password);
        }

        this.verifyElementIsVisible(hpe.LOGIN_DIALOG_LOGIN_BUTTON, 'Log In');
        cy.get(hpe.LOGIN_DIALOG_LOGIN_BUTTON).click({force: true});
        this.verifyElementDoesNotExist(hpe.LOGIN_DIALOG);
    }
}

export default LearnPortalHomePage;
