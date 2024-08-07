/**
 * This file models the learn-report report learner page, that is, in production, the one with this URL:
 *     https://learn-report.concord.org/auth/login
 * or on staging:
 *     https://learn-report.portal.staging.concord.org/report/learner
 * 
 * Note: this is currently far from complete, but may grow as needed for additional tests.
 */

const rlpe = {    // (learn-report) report learner page elements
    SCHOOLS_DROPDOWN:           'input[id="react-select-2-input"]',
    TEACHERS_DROPDOWN:          'input[id="react-select-3-input"]',
    RESOURCES_DROPDOWN:         'input[id="react-select-4-input"]',
    PERMISSION_FORMS_DROPDOWN:  'input[id="react-select-5-input"]',
    START_DATE_INPUT:           'input[name="start_date"]',
    END_DATE_INPUT:             'input[name="end_date"]',
    DETAILS_REPORT_BUTTON:      'input[value="Details Report"]',
    LERNER_LOG_BUTTON:          'input[value="Learner Log"]',
    LERNER_LOG_EXPANDED_BUTTON: 'input[value="Learner Log (Expanded)"]',
    USAGE_REPORT_BUTTON:        'input[value="Usage Report"]',
}

class LearnReportReportLearnerPage {

    // Utility methods, used below
    verifyElementIsVisible(selector) {
        cy.get(selector).should('be.visible');
    }
    selectElement(selector, text) {
        this.verifyElementIsVisible(selector);
        cy.get(selector).type(text+'\n');
    }
    clickButton(selector) {
        cy.get(selector).should('be.visible').then(($button) => {
            // Remove target="_blank", so the link opens in the same tab
            $button.attr('target', null);
        }).click({force: true});
    }

    selectSchool(name) {
        this.selectElement(rlpe.SCHOOLS_DROPDOWN, name);
    }
    selectTeacher(name) {
        this.selectElement(rlpe.TEACHERS_DROPDOWN, name);
    }
    selectResource(name) {
        this.selectElement(rlpe.RESOURCES_DROPDOWN, name);
    }
    selectPermissionForm(name) {
        this.selectElement(rlpe.PERMISSION_FORMS_DROPDOWN, name);
    }

    selectStartDate(date) {
        this.selectElement(rlpe.START_DATE_INPUT, name);
    }
    selectEndDate(date) {
        this.selectElement(rlpe.END_DATE_INPUT, name);
    }

    clickDetailsReportButton() {
        this.clickButton(rlpe.DETAILS_REPORT_BUTTON);
    }
    clickLearnerLogButton() {
        this.clickButton(rlpe.LERNER_LOG_BUTTON);
    }
    clickLearnerLogExpandedButton() {
        this.clickButton(rlpe.LERNER_LOG_EXPANDED_BUTTON);
    }
    clickUsageReportButton() {
        this.clickButton(rlpe.USAGE_REPORT_BUTTON);
    }

    // A method that combines all of the above into one
    showReport(buttonSelector, school, teacher=null, resource=null, permissionForm=null, startDate=null, endDate=null) {
        if (school != null) {
            this.selectSchool(school);
        }
        if (teacher != null) {
            this.selectTeacher(teacher);
        }
        if (resource != null) {
            this.selectResource(resource);
        }
        if (permissionForm != null) {
            this.selectPermissionForm(permissionForm);
        }
        if (startDate != null) {
            this.selectStartDate(startDate);
        }
        if (endDate != null) {
            this.selectEndDate(endDate);
        }

        this.clickButton(buttonSelector);
    }

    // Combined method for a Details Report, i.e., clicking the 'Details Report' button at the end
    showDetailsReport(school, teacher=null, resource=null, permissionForm=null, startDate=null, endDate=null) {
        this.showReport(rlpe.DETAILS_REPORT_BUTTON, school, teacher, resource, permissionForm, startDate, endDate);
    }

}

export default LearnReportReportLearnerPage;
